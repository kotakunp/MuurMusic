import Foundation

/// A recording candidate from MusicBrainz.
public struct MusicBrainzRecordingMatch: Hashable, Sendable, Identifiable {
    public var id: String { recordingID + ":" + (releaseID ?? "") }
    public var recordingID: String
    public var title: String
    public var artist: String
    public var album: String?
    public var albumArtist: String?
    public var releaseID: String?
    public var releaseGroupID: String?
    public var year: Int?
    public var trackNumber: Int?
    public var trackTotal: Int?
    public var discNumber: Int?
    public var duration: Double?
    /// MusicBrainz search score (0-100).
    public var score: Int
}

/// A release candidate from MusicBrainz.
public struct MusicBrainzReleaseMatch: Hashable, Sendable, Identifiable {
    public var id: String { releaseID }
    public var releaseID: String
    public var releaseGroupID: String?
    public var title: String
    public var artist: String
    public var year: Int?
    public var trackCount: Int?
    public var score: Int
}

/// A release with its track list.
public struct MusicBrainzRelease: Hashable, Sendable {
    public struct Track: Hashable, Sendable {
        public var discNumber: Int
        public var position: Int
        public var title: String
        public var artist: String
        public var recordingID: String?
        public var duration: Double?
    }

    public var releaseID: String
    public var releaseGroupID: String?
    public var title: String
    public var artist: String
    public var year: Int?
    public var tracks: [Track]
}

/// MusicBrainz web service (JSON) and Cover Art Archive client. Requests to musicbrainz.org are limited to
/// one per second and identify the app with the required User-Agent.
public final class MusicBrainzClient: Sendable {
    public static let baseURL = URL(string: "https://musicbrainz.org/ws/2/")!
    public static let coverArtBaseURL = URL(string: "https://coverartarchive.org/")!

    private let http: HTTPClient
    private let limiter = RateLimiter(interval: 1.05)

    public init(http: HTTPClient = .shared) {
        self.http = http
    }

    // MARK: Wire format

    private struct ArtistCredit: Decodable {
        var name: String?
        var joinphrase: String?
    }

    private struct ReleaseGroup: Decodable {
        var id: String?
    }

    private struct MediumTrack: Decodable {
        var position: Int?
        var number: String?
        var title: String?
        var length: Double?
        var recording: RecordingRef?
        var artistCredit: [ArtistCredit]?

        enum CodingKeys: String, CodingKey {
            case position, number, title, length, recording
            case artistCredit = "artist-credit"
        }
    }

    private struct RecordingRef: Decodable {
        var id: String?
        var title: String?
    }

    private struct Medium: Decodable {
        var position: Int?
        var trackCount: Int?
        var trackOffset: Int?
        var track: [MediumTrack]?
        var tracks: [MediumTrack]?

        enum CodingKeys: String, CodingKey {
            case position, track, tracks
            case trackCount = "track-count"
            case trackOffset = "track-offset"
        }
    }

    private struct Release: Decodable {
        var id: String
        var title: String?
        var status: String?
        var date: String?
        var score: Int?
        var trackCount: Int?
        var artistCredit: [ArtistCredit]?
        var releaseGroup: ReleaseGroup?
        var media: [Medium]?

        enum CodingKeys: String, CodingKey {
            case id, title, status, date, score, media
            case trackCount = "track-count"
            case artistCredit = "artist-credit"
            case releaseGroup = "release-group"
        }
    }

    private struct Recording: Decodable {
        var id: String
        var score: Int?
        var title: String?
        var length: Double?
        var artistCredit: [ArtistCredit]?
        var releases: [Release]?

        enum CodingKeys: String, CodingKey {
            case id, score, title, length, releases
            case artistCredit = "artist-credit"
        }
    }

    private struct RecordingSearch: Decodable { var recordings: [Recording]? }
    private struct ReleaseSearch: Decodable { var releases: [Release]? }

    private static func credit(_ credits: [ArtistCredit]?) -> String {
        (credits ?? []).map { ($0.name ?? "") + ($0.joinphrase ?? "") }.joined()
    }

    /// Escapes a term for a quoted Lucene phrase.
    static func phrase(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func get<T: Decodable>(_ path: String, query: [String: String]) async throws -> T {
        guard !MuurSettings.Snapshot.current().offlineMode else { throw MuurError.offline }
        var components = URLComponents(url: MusicBrainzClient.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        var items = query
        items["fmt"] = "json"
        components.setQuery(items)
        guard let url = components.url else { throw MuurError.invalidData("Bad MusicBrainz query") }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(HTTPClient.userAgent, forHTTPHeaderField: "User-Agent")
        for attempt in 0..<3 {
            await limiter.wait()
            do {
                return try await http.json(T.self, for: request)
            } catch MuurError.http(let status, _) where status == 503 && attempt < 2 {
                try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_500_000_000)
            }
        }
        throw MuurError.network("MusicBrainz is busy, try again later")
    }

    // MARK: Searches

    public func searchRecordings(title: String, artist: String?, album: String?, duration: Double?, limit: Int = 10) async throws -> [MusicBrainzRecordingMatch] {
        var terms = ["recording:" + MusicBrainzClient.phrase(title)]
        if let artist, !artist.isEmpty { terms.append("artist:" + MusicBrainzClient.phrase(artist)) }
        if let album, !album.isEmpty { terms.append("release:" + MusicBrainzClient.phrase(album)) }
        if let duration, duration > 0 {
            let ms = Int(duration * 1000)
            terms.append("dur:[\(max(0, ms - 4000)) TO \(ms + 4000)]")
        }
        let response: RecordingSearch = try await get("recording", query: ["query": terms.joined(separator: " AND "), "limit": String(limit)])
        var matches: [MusicBrainzRecordingMatch] = []
        for recording in response.recordings ?? [] {
            let releases = (recording.releases ?? []).sorted { lhs, rhs in
                (lhs.status == "Official" ? 0 : 1) < (rhs.status == "Official" ? 0 : 1)
            }
            let release = releases.first { album == nil || $0.title?.caseInsensitiveCompare(album ?? "") == .orderedSame } ?? releases.first
            let medium = release?.media?.first
            let mediumTrack = medium?.track?.first
            let position = mediumTrack?.number.flatMap { Int($0) } ?? mediumTrack?.position
            matches.append(MusicBrainzRecordingMatch(
                recordingID: recording.id,
                title: recording.title ?? title,
                artist: MusicBrainzClient.credit(recording.artistCredit),
                album: release?.title,
                albumArtist: release.map { MusicBrainzClient.credit($0.artistCredit) }.flatMap { $0.isEmpty ? nil : $0 },
                releaseID: release?.id,
                releaseGroupID: release?.releaseGroup?.id,
                year: DateParsing.year(from: release?.date),
                trackNumber: position,
                trackTotal: medium?.trackCount ?? release?.trackCount,
                discNumber: medium?.position,
                duration: recording.length.map { $0 / 1000 },
                score: recording.score ?? 0))
        }
        return matches.sorted { $0.score > $1.score }
    }

    public func searchReleases(album: String, artist: String?, limit: Int = 10) async throws -> [MusicBrainzReleaseMatch] {
        var terms = ["release:" + MusicBrainzClient.phrase(album)]
        if let artist, !artist.isEmpty { terms.append("artist:" + MusicBrainzClient.phrase(artist)) }
        let response: ReleaseSearch = try await get("release", query: ["query": terms.joined(separator: " AND "), "limit": String(limit)])
        return (response.releases ?? []).map { release in
            MusicBrainzReleaseMatch(releaseID: release.id, releaseGroupID: release.releaseGroup?.id, title: release.title ?? album,
                                    artist: MusicBrainzClient.credit(release.artistCredit), year: DateParsing.year(from: release.date),
                                    trackCount: release.trackCount, score: release.score ?? 0)
        }.sorted { $0.score > $1.score }
    }

    /// Full release with tracks.
    public func release(id: String) async throws -> MusicBrainzRelease {
        let release: Release = try await get("release/\(id)", query: ["inc": "recordings+artist-credits+release-groups"])
        let albumArtist = MusicBrainzClient.credit(release.artistCredit)
        var tracks: [MusicBrainzRelease.Track] = []
        for medium in release.media ?? [] {
            for track in medium.tracks ?? medium.track ?? [] {
                let artist = MusicBrainzClient.credit(track.artistCredit)
                tracks.append(MusicBrainzRelease.Track(discNumber: medium.position ?? 1,
                                                       position: track.number.flatMap { Int($0) } ?? track.position ?? tracks.count + 1,
                                                       title: track.title ?? track.recording?.title ?? "",
                                                       artist: artist.isEmpty ? albumArtist : artist,
                                                       recordingID: track.recording?.id,
                                                       duration: track.length.map { $0 / 1000 }))
            }
        }
        return MusicBrainzRelease(releaseID: release.id, releaseGroupID: release.releaseGroup?.id, title: release.title ?? "",
                                  artist: albumArtist, year: DateParsing.year(from: release.date), tracks: tracks)
    }

    // MARK: Cover Art Archive

    /// Front cover image data (`size` 250, 500 or 1200; nil = original) or nil when the release has none.
    public func frontCover(releaseID: String, size: Int? = 500) async throws -> Data? {
        try await coverArt(path: "release/\(releaseID)/front" + (size.map { "-\($0)" } ?? ""))
    }

    public func frontCover(releaseGroupID: String, size: Int? = 500) async throws -> Data? {
        try await coverArt(path: "release-group/\(releaseGroupID)/front" + (size.map { "-\($0)" } ?? ""))
    }

    private func coverArt(path: String) async throws -> Data? {
        guard !MuurSettings.Snapshot.current().offlineMode else { throw MuurError.offline }
        let url = MusicBrainzClient.coverArtBaseURL.appendingPathComponent(path)
        let (data, response) = try await http.data(for: URLRequest(url: url), validate: false)
        if response.statusCode == 404 { return nil }
        guard (200..<300).contains(response.statusCode) else { throw MuurError.http(status: response.statusCode, message: "") }
        return data.isEmpty ? nil : data
    }
}

/// Matches library tracks against MusicBrainz and fills in missing tags and artwork.
public final class MetadataLookupService: Sendable {
    public let client: MusicBrainzClient
    public let artwork: ArtworkCache
    public let repository: LibraryRepository

    public init(client: MusicBrainzClient = MusicBrainzClient(), artwork: ArtworkCache, repository: LibraryRepository) {
        self.client = client
        self.artwork = artwork
        self.repository = repository
    }

    /// Candidate recordings for a track, best first.
    public func candidates(for track: Track) async throws -> [MusicBrainzRecordingMatch] {
        let title = track.displayTitle
        let artist = track.artist.isEmpty ? nil : track.artist
        let album = track.album.isEmpty ? nil : track.album
        var results = try await client.searchRecordings(title: title, artist: artist, album: album,
                                                        duration: track.duration > 0 ? track.duration : nil)
        if results.isEmpty && album != nil {
            results = try await client.searchRecordings(title: title, artist: artist, album: nil, duration: nil)
        }
        return results
    }

    /// The best candidate when it is confident enough (score >= 90 and duration within 5 s when known).
    public func bestMatch(for track: Track) async throws -> MusicBrainzRecordingMatch? {
        guard let best = try await candidates(for: track).first, best.score >= 90 else { return nil }
        if track.duration > 0, let duration = best.duration, abs(duration - track.duration) > 5 { return nil }
        return best
    }

    /// Applies a match: fills empty fields (or all fields when `overwrite`), stores IDs and fetches cover art
    /// when the track has none. Writes tags to the file when `tagEditor` is given and the file is writable.
    @discardableResult
    public func apply(_ match: MusicBrainzRecordingMatch, to track: Track, overwrite: Bool = false,
                      tagEditor: TagEditor? = nil) async throws -> Track {
        var updated = track
        func fill(_ keyPath: WritableKeyPath<Track, String>, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            if overwrite || updated[keyPath: keyPath].isEmpty { updated[keyPath: keyPath] = value }
        }
        fill(\.title, match.title)
        fill(\.artist, match.artist)
        fill(\.album, match.album)
        if let albumArtist = match.albumArtist, albumArtist != match.artist { fill(\.albumArtist, albumArtist) }
        if overwrite || updated.year == nil { updated.year = match.year ?? updated.year }
        if overwrite || updated.trackNumber == nil { updated.trackNumber = match.trackNumber ?? updated.trackNumber }
        if overwrite || updated.trackTotal == nil { updated.trackTotal = match.trackTotal ?? updated.trackTotal }
        if overwrite || updated.discNumber == nil { updated.discNumber = match.discNumber ?? updated.discNumber }
        updated.musicBrainzRecordingID = match.recordingID
        updated.musicBrainzReleaseID = match.releaseID ?? updated.musicBrainzReleaseID
        var artworkChange = ArtworkChange.keep
        if updated.artworkKey == nil, let releaseID = match.releaseID {
            var data = try? await client.frontCover(releaseID: releaseID)
            if data == nil, let groupID = match.releaseGroupID { data = try? await client.frontCover(releaseGroupID: groupID) }
            if let data {
                updated.artworkKey = artwork.store(data)
                artworkChange = .replace(data)
            }
        }
        if let tagEditor {
            return try await tagEditor.save(updated, artwork: artworkChange)
        }
        try await repository.update(updated)
        return updated
    }

    /// Fetches album artwork for every track of `album` from the Cover Art Archive. Returns the artwork key.
    @discardableResult
    public func fetchArtwork(for album: Album) async throws -> String? {
        let tracks = try await repository.tracks(album: album)
        var releaseID = tracks.compactMap(\.musicBrainzReleaseID).first
        var groupID: String?
        if releaseID == nil {
            let releases = try await client.searchReleases(album: album.title, artist: album.artist.isEmpty ? nil : album.artist, limit: 5)
            guard let best = releases.first, best.score >= 85 else { return nil }
            releaseID = best.releaseID
            groupID = best.releaseGroupID
        }
        guard let releaseID else { return nil }
        var data = try await client.frontCover(releaseID: releaseID, size: 1200)
        if data == nil, let groupID { data = try await client.frontCover(releaseGroupID: groupID, size: 1200) }
        guard let data, let key = artwork.store(data) else { return nil }
        try await repository.setArtworkKey(key, trackIDs: tracks.compactMap(\.id))
        return key
    }

    /// Auto-tags tracks that miss essential tags (used after scans when "auto-tag online" is on).
    public func autoTag(_ tracks: [Track], tagEditor: TagEditor? = nil) async -> Int {
        var count = 0
        for track in tracks where track.musicBrainzRecordingID == nil && (track.artist.isEmpty || track.album.isEmpty || track.artworkKey == nil) {
            if Task.isCancelled { break }
            guard let match = try? await bestMatch(for: track) else { continue }
            if (try? await apply(match, to: track, tagEditor: tagEditor)) != nil { count += 1 }
        }
        return count
    }
}
