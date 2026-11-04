import Foundation

/// One entry read from (or written to) an M3U / M3U8 / PLS playlist.
public struct PlaylistEntry: Hashable, Sendable {
    /// Location exactly as written in the file.
    public var location: String
    /// Source URI after resolving `location` against the playlist location, or nil when unresolvable
    /// (e.g. a Windows drive path). Unresolved entries can still be matched by file name.
    public var resolvedURI: String?
    public var duration: Double?
    public var title: String?
    public var artist: String?

    public init(location: String, resolvedURI: String?, duration: Double? = nil, title: String? = nil, artist: String? = nil) {
        self.location = location
        self.resolvedURI = resolvedURI
        self.duration = duration
        self.title = title
        self.artist = artist
    }

    /// File name component of the location (handles `/` and `\` separators).
    public var fileName: String {
        PathUtils.lastComponent(location.replacingOccurrences(of: "\\", with: "/"))
    }
}

/// A track to be written into a playlist file.
public struct PlaylistWriteItem: Hashable, Sendable {
    public var uri: String
    public var duration: Double
    public var artist: String
    public var title: String

    public init(uri: String, duration: Double, artist: String, title: String) {
        self.uri = uri
        self.duration = duration
        self.artist = artist
        self.title = title
    }

    public init(track: Track) {
        self.init(uri: track.sourceURI, duration: track.duration, artist: track.artist, title: track.displayTitle)
    }
}

/// Text decoding helpers for playlist / CUE / LRC files of unknown encoding.
public enum TextDecoding {
    /// Decodes UTF-8 (with or without BOM), UTF-16 with BOM, otherwise Windows-1252.
    public static func decode(_ data: Data) -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(decoding: data.dropFirst(3), as: UTF8.self)
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            if let text = String(data: data, encoding: .utf16) { return text }
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .windowsCP1252) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    /// Splits text into lines accepting `\n`, `\r\n` and `\r`.
    public static func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }
}

/// Resolves playlist locations relative to the playlist's own source URI.
public enum PlaylistPathResolver {
    /// Schemes whose URIs carry a hierarchical path, so relative locations can be resolved.
    static let pathSchemes: Set<String> = ["file", "smb", "webdav", "webdavs", "ftp", "ftps", "sftp", "dropbox", "s3"]

    /// Removes `.` and `..` components and duplicate slashes from an absolute path.
    public static func normalize(_ path: String) -> String {
        var stack: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                if !stack.isEmpty { stack.removeLast() }
                continue
            }
            stack.append(component)
        }
        return "/" + stack.joined(separator: "/")
    }

    /// Resolves `location` against `baseURI` (the URI of the playlist file itself).
    public static func resolve(_ location: String, baseURI: String?) -> String? {
        var value = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) != nil {
            if value.lowercased().hasPrefix("file://"), let url = URL(string: value) {
                return SourceURI.file(url)
            }
            return value
        }
        value = value.replacingOccurrences(of: "\\", with: "/")
        if value.range(of: "^[A-Za-z]:/", options: .regularExpression) != nil || value.hasPrefix("//") {
            return nil
        }
        guard let baseURI else {
            return value.hasPrefix("/") ? SourceURI.file(URL(fileURLWithPath: normalize(value))) : nil
        }
        if baseURI.hasPrefix("zip://"), let parsed = SourceURI.parse(baseURI), let parts = parsed.zipComponents {
            let entryDir = PathUtils.parent("/" + parts.entry)
            let path = value.hasPrefix("/") ? normalize(value) : normalize(PathUtils.join(entryDir.isEmpty ? "/" : entryDir, value))
            return SourceURI.zip(inner: parts.inner, entry: String(path.dropFirst()))
        }
        guard let base = SourceURI.parse(baseURI), pathSchemes.contains(base.scheme) else { return nil }
        let basePath = base.path.hasPrefix("/") ? base.path : "/" + base.path
        let directory = PathUtils.parent(basePath)
        let path = value.hasPrefix("/") ? normalize(value) : normalize(PathUtils.join(directory.isEmpty ? "/" : directory, value))
        if base.scheme == "file" {
            return SourceURI.file(URL(fileURLWithPath: path))
        }
        var result = base
        result.path = SourceURI.idBasedSchemes.contains(base.scheme) ? String(path.dropFirst()) : path
        return result.description
    }

    /// Location to write for `uri` inside a playlist stored at `playlistURI`: a relative path when the track
    /// lives below the playlist's folder on the same source, otherwise an absolute path (local files) or the URI.
    public static func relativeLocation(for uri: String, playlistURI: String?) -> String {
        guard let track = SourceURI.parse(uri) else { return uri }
        if let playlistURI, let playlist = SourceURI.parse(playlistURI), playlist.scheme == track.scheme,
           playlist.authority == track.authority, playlist.port == track.port, pathSchemes.contains(track.scheme) {
            let playlistPath = playlist.path.hasPrefix("/") ? playlist.path : "/" + playlist.path
            let trackPath = track.path.hasPrefix("/") ? track.path : "/" + track.path
            let directory = PathUtils.parent(playlistPath)
            let prefix = directory.hasSuffix("/") ? directory : directory + "/"
            if trackPath.hasPrefix(prefix) {
                return String(trackPath.dropFirst(prefix.count))
            }
        }
        if track.isFile { return track.path }
        return uri
    }
}

/// M3U / M3U8 reading and writing (SHARED_FORMATS "Playlists").
public enum M3UPlaylist {
    public static func parse(data: Data, baseURI: String?) -> [PlaylistEntry] {
        parse(TextDecoding.decode(data), baseURI: baseURI)
    }

    public static func parse(_ text: String, baseURI: String?) -> [PlaylistEntry] {
        var entries: [PlaylistEntry] = []
        var pendingDuration: Double?
        var pendingTitle: String?
        var pendingArtist: String?
        for rawLine in TextDecoding.lines(text) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                if line.uppercased().hasPrefix("#EXTINF:") {
                    let info = parseExtInf(String(line.dropFirst("#EXTINF:".count)))
                    pendingDuration = info.duration
                    pendingTitle = info.title
                    pendingArtist = info.artist
                }
                continue
            }
            entries.append(PlaylistEntry(location: line, resolvedURI: PlaylistPathResolver.resolve(line, baseURI: baseURI),
                                         duration: pendingDuration, title: pendingTitle, artist: pendingArtist))
            pendingDuration = nil
            pendingTitle = nil
            pendingArtist = nil
        }
        return entries
    }

    /// Parses the part after `#EXTINF:` - `<seconds>[ attributes],<artist> - <title>`.
    static func parseExtInf(_ body: String) -> (duration: Double?, artist: String?, title: String?) {
        var inQuotes = false
        var commaIndex: String.Index?
        for index in body.indices {
            let character = body[index]
            if character == "\"" { inQuotes.toggle() }
            if character == "," && !inQuotes {
                commaIndex = index
                break
            }
        }
        let head = commaIndex.map { String(body[..<$0]) } ?? body
        let display = commaIndex.map { String(body[body.index(after: $0)...]) }?.trimmingCharacters(in: .whitespaces) ?? ""
        let durationText = head.split(separator: " ").first.map(String.init) ?? head
        var duration = Double(durationText.trimmingCharacters(in: .whitespaces))
        if let value = duration, value < 0 { duration = nil }
        guard !display.isEmpty else { return (duration, nil, nil) }
        if let range = display.range(of: " - ") {
            let artist = String(display[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let title = String(display[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            return (duration, artist.isEmpty ? nil : artist, title.isEmpty ? nil : title)
        }
        return (duration, nil, display)
    }

    /// Serializes items as extended M3U. `playlistURI` (the file's own URI) enables relative paths.
    public static func write(_ items: [PlaylistWriteItem], playlistURI: String?) -> String {
        var output = "#EXTM3U\n"
        for item in items {
            let seconds = item.duration > 0 ? Int(item.duration.rounded()) : -1
            let display = item.artist.isEmpty ? item.title : "\(item.artist) - \(item.title)"
            output += "#EXTINF:\(seconds),\(display.replacingOccurrences(of: "\n", with: " "))\n"
            output += PlaylistPathResolver.relativeLocation(for: item.uri, playlistURI: playlistURI) + "\n"
        }
        return output
    }
}

/// PLS playlist reading and writing.
public enum PLSPlaylist {
    public static func parse(_ text: String, baseURI: String?) -> [PlaylistEntry] {
        var files: [Int: String] = [:]
        var titles: [Int: String] = [:]
        var lengths: [Int: Double] = [:]
        for rawLine in TextDecoding.lines(text) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].lowercased()
            let value = String(line[line.index(after: equals)...])
            func number(_ prefix: String) -> Int? {
                key.hasPrefix(prefix) ? Int(key.dropFirst(prefix.count)) : nil
            }
            if let n = number("file") { files[n] = value }
            else if let n = number("title") { titles[n] = value }
            else if let n = number("length"), let seconds = Double(value), seconds >= 0 { lengths[n] = seconds }
        }
        return files.keys.sorted().compactMap { n in
            guard let location = files[n] else { return nil }
            var title = titles[n]
            var artist: String?
            if let display = title, let range = display.range(of: " - ") {
                artist = String(display[..<range.lowerBound])
                title = String(display[range.upperBound...])
            }
            return PlaylistEntry(location: location, resolvedURI: PlaylistPathResolver.resolve(location, baseURI: baseURI),
                                 duration: lengths[n], title: title, artist: artist)
        }
    }

    public static func write(_ items: [PlaylistWriteItem], playlistURI: String?) -> String {
        var output = "[playlist]\n"
        for (index, item) in items.enumerated() {
            let n = index + 1
            output += "File\(n)=\(PlaylistPathResolver.relativeLocation(for: item.uri, playlistURI: playlistURI))\n"
            output += "Title\(n)=\(item.artist.isEmpty ? item.title : "\(item.artist) - \(item.title)")\n"
            output += "Length\(n)=\(item.duration > 0 ? Int(item.duration.rounded()) : -1)\n"
        }
        output += "NumberOfEntries=\(items.count)\nVersion=2\n"
        return output
    }
}
