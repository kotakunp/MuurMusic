import Foundation

/// Finds lyrics for a track: user-edited lyrics, sidecar `.lrc` files, embedded tags, then LRCLIB
/// (online, cached). Online lookups respect offline mode and the "fetch lyrics online" setting.
public final class LyricsService: Sendable {
    public static let lrclibBaseURL = URL(string: "https://lrclib.net/api/")!

    public let paths: AppPaths
    private let http: HTTPClient
    private let memory = LockedValue<[String: Lyrics]>([:])
    private let defaults: UserDefaults

    public init(paths: AppPaths, http: HTTPClient = .shared, defaults: UserDefaults = .standard) {
        self.paths = paths
        self.http = http
        self.defaults = defaults
    }

    private func cacheBase(for track: Track) -> URL {
        paths.lyricsCacheDirectory.appendingPathComponent(String(Hashing.sha256Hex(track.libraryKey).prefix(32)))
    }

    /// Best lyrics for `track`, or nil. Set `allowOnline` false to skip LRCLIB.
    public func lyrics(for track: Track, allowOnline: Bool = true) async -> Lyrics? {
        if let cached = memory.get()[track.libraryKey] { return cached }
        let found = await findLyrics(for: track, allowOnline: allowOnline)
        if let found { memory.mutate { $0[track.libraryKey] = found } }
        return found
    }

    private func findLyrics(for track: Track, allowOnline: Bool) async -> Lyrics? {
        let base = cacheBase(for: track)
        if let text = try? String(contentsOf: base.appendingPathExtension("user.lrc"), encoding: .utf8) {
            let parsed = LRCParser.parse(text, origin: .user)
            if !parsed.isEmpty { return parsed }
        }
        if let sidecar = sidecarLyrics(for: track) { return sidecar }
        if let embedded = track.lyrics, !embedded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return windowed(LRCParser.parse(embedded, origin: .embedded), for: track)
        }
        let lrclibCache = base.appendingPathExtension("lrclib.lrc")
        if let text = try? String(contentsOf: lrclibCache, encoding: .utf8) {
            let parsed = LRCParser.parse(text, origin: .lrclib)
            return parsed.isEmpty ? nil : parsed
        }
        let settings = MuurSettings.Snapshot.current(defaults: defaults)
        guard allowOnline, settings.fetchLyricsOnline, !settings.offlineMode else { return nil }
        guard let text = try? await fetchFromLRCLIB(track: track) else { return nil }
        try? FileManager.default.createDirectory(at: paths.lyricsCacheDirectory, withIntermediateDirectories: true)
        try? text.write(to: lrclibCache, atomically: true, encoding: .utf8)
        let parsed = LRCParser.parse(text, origin: .lrclib)
        return parsed.isEmpty ? nil : parsed
    }

    /// Sidecar `<audio base name>.lrc` / `.txt` next to a local file.
    func sidecarLyrics(for track: Track) -> Lyrics? {
        guard track.isLocal, let url = URL(string: track.sourceURI) else { return nil }
        let fileURL = paths.resolveStoredFileURL(url)
        let base = fileURL.deletingPathExtension()
        for ext in ["lrc", "LRC", "txt"] {
            let candidate = base.appendingPathExtension(ext)
            guard let data = try? Data(contentsOf: candidate) else { continue }
            let parsed = LRCParser.parse(TextDecoding.decode(data), origin: .sidecar)
            if !parsed.isEmpty { return windowed(parsed, for: track) }
        }
        return nil
    }

    /// For CUE tracks, shifts whole-file synced lyrics into the track window.
    func windowed(_ lyrics: Lyrics, for track: Track) -> Lyrics {
        guard lyrics.isSynced, let start = track.cueStart else { return lyrics }
        let end = track.cueEnd ?? .greatestFiniteMagnitude
        let inside = lyrics.lines.filter { line in
            guard let time = line.time else { return false }
            return time >= start - 0.5 && time < end
        }
        guard !inside.isEmpty else { return lyrics }
        var result = lyrics
        result.lines = inside.enumerated().map { index, line in
            LyricLine(id: index, time: max(0, (line.time ?? start) - start), text: line.text)
        }
        return result
    }

    private struct LRCLIBRecord: Decodable {
        var id: Int?
        var trackName: String?
        var artistName: String?
        var albumName: String?
        var duration: Double?
        var instrumental: Bool?
        var plainLyrics: String?
        var syncedLyrics: String?
    }

    /// Queries LRCLIB: exact `get` first, then `search`, preferring synced lyrics and a close duration.
    public func fetchFromLRCLIB(track: Track) async throws -> String? {
        let title = track.displayTitle
        let artist = track.displayArtist
        guard !title.isEmpty else { return nil }
        var components = URLComponents(url: LyricsService.lrclibBaseURL.appendingPathComponent("get"), resolvingAgainstBaseURL: false)!
        var query: [String: String] = ["track_name": title, "artist_name": artist]
        if !track.album.isEmpty { query["album_name"] = track.album }
        if track.duration > 0 { query["duration"] = String(Int(track.duration.rounded())) }
        components.setQuery(query)
        if let url = components.url {
            let (data, response) = try await http.data(for: URLRequest(url: url), validate: false)
            if response.statusCode == 200, let record = try? JSONDecoder().decode(LRCLIBRecord.self, from: data),
               let text = LyricsService.bestText(record) {
                return text
            }
        }
        var search = URLComponents(url: LyricsService.lrclibBaseURL.appendingPathComponent("search"), resolvingAgainstBaseURL: false)!
        search.setQuery(["track_name": title, "artist_name": artist])
        guard let searchURL = search.url else { return nil }
        let (data, response) = try await http.data(for: URLRequest(url: searchURL), validate: false)
        guard response.statusCode == 200, let records = try? JSONDecoder().decode([LRCLIBRecord].self, from: data) else { return nil }
        let ranked = records.filter { LyricsService.bestText($0) != nil }.sorted { lhs, rhs in
            func score(_ record: LRCLIBRecord) -> Double {
                var value: Double = record.syncedLyrics?.isEmpty == false ? 0 : 50
                if track.duration > 0, let duration = record.duration { value += abs(duration - track.duration) } else { value += 20 }
                return value
            }
            return score(lhs) < score(rhs)
        }
        guard let best = ranked.first else { return nil }
        if track.duration > 0, let duration = best.duration, abs(duration - track.duration) > 15 { return nil }
        return LyricsService.bestText(best)
    }

    private static func bestText(_ record: LRCLIBRecord) -> String? {
        if let synced = record.syncedLyrics, !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return synced }
        if let plain = record.plainLyrics, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return plain }
        return nil
    }

    /// Stores user-edited lyrics (LRC or plain). They take precedence over every other origin.
    public func saveUserLyrics(_ text: String, for track: Track) throws {
        try FileManager.default.createDirectory(at: paths.lyricsCacheDirectory, withIntermediateDirectories: true)
        try text.write(to: cacheBase(for: track).appendingPathExtension("user.lrc"), atomically: true, encoding: .utf8)
        memory.mutate { $0[track.libraryKey] = nil }
    }

    public func removeUserLyrics(for track: Track) {
        try? FileManager.default.removeItem(at: cacheBase(for: track).appendingPathExtension("user.lrc"))
        memory.mutate { $0[track.libraryKey] = nil }
    }

    /// Forgets cached LRCLIB results for a track (forces a new online lookup).
    public func clearCachedLyrics(for track: Track) {
        try? FileManager.default.removeItem(at: cacheBase(for: track).appendingPathExtension("lrclib.lrc"))
        memory.mutate { $0[track.libraryKey] = nil }
    }

    public func clearMemoryCache() {
        memory.set([:])
    }
}
