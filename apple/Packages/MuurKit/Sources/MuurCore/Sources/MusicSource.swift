import Foundation

/// An entry returned when browsing a source.
public struct SourceItem: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case folder, audio, playlist, archive, image, lyrics, other
    }

    public var id: String { uri }
    /// Source URI of the item (tracks: playable URI; folders: a URI that `list` understands).
    public var uri: String
    public var name: String
    public var kind: Kind
    /// Source-internal location used to list children / download (path, object id, `album:<id>`...).
    public var path: String
    public var size: Int64?
    public var modified: Date?
    public var mimeType: String?
    /// Metadata pre-filled by media servers and DLNA (nil for plain file servers).
    public var track: Track?
    /// Remote artwork (media servers), fetched with `artworkHeaders`.
    public var artworkURL: URL?
    public var artworkHeaders: [String: String]
    public var childCount: Int?
    /// Secondary text for lists (artist, album count...).
    public var subtitle: String?

    public init(uri: String, name: String, kind: Kind, path: String, size: Int64? = nil, modified: Date? = nil,
                mimeType: String? = nil, track: Track? = nil, artworkURL: URL? = nil, artworkHeaders: [String: String] = [:],
                childCount: Int? = nil, subtitle: String? = nil) {
        self.uri = uri
        self.name = name
        self.kind = kind
        self.path = path
        self.size = size
        self.modified = modified
        self.mimeType = mimeType
        self.track = track
        self.artworkURL = artworkURL
        self.artworkHeaders = artworkHeaders
        self.childCount = childCount
        self.subtitle = subtitle
    }

    public var isContainer: Bool { kind == .folder || kind == .archive }
    public var isPlayable: Bool { kind == .audio }

    /// Classifies a file name.
    public static func kind(forFileName name: String) -> Kind {
        let ext = PathUtils.fileExtension(name)
        if PathUtils.isAudio(name) { return .audio }
        if PathUtils.isPlaylist(name) { return .playlist }
        if PathUtils.isArchive(name) { return .archive }
        if PathUtils.imageExtensions.contains(ext) { return .image }
        if PathUtils.lyricsExtensions.contains(ext) { return .lyrics }
        return .other
    }
}

/// What a source supports.
public struct SourceCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let browse = SourceCapabilities(rawValue: 1 << 0)
    public static let search = SourceCapabilities(rawValue: 1 << 1)
    public static let upload = SourceCapabilities(rawValue: 1 << 2)
    public static let delete = SourceCapabilities(rawValue: 1 << 3)
    public static let rename = SourceCapabilities(rawValue: 1 << 4)
    public static let createFolder = SourceCapabilities(rawValue: 1 << 5)
    /// `streamURL(for:)` returns a direct HTTP(S) URL (usable for casting to DLNA renderers).
    public static let directURL = SourceCapabilities(rawValue: 1 << 6)
    /// `libraryTracks()` returns the server's complete music library (media servers).
    public static let library = SourceCapabilities(rawValue: 1 << 7)

    public static let fileServer: SourceCapabilities = [.browse, .upload, .delete, .rename, .createFolder]
}

/// A direct HTTP resource for a remote item.
public struct RemoteResource: Sendable, Hashable {
    public var url: URL
    public var headers: [String: String]

    public init(url: URL, headers: [String: String] = [:]) {
        self.url = url
        self.headers = headers
    }
}

/// Common interface of every browsable source (local folders, network shares, cloud drives, media servers).
///
/// Implementations are `Sendable` reference types; all methods are async and may be called from any context.
/// Remote audio is played by downloading it into the audio cache (`SourceManager.playableURL(for:)`).
public protocol MusicSource: AnyObject, Sendable {
    var config: SourceConfig { get }
    var capabilities: SourceCapabilities { get }

    /// Verifies connectivity and credentials.
    func connect() async throws
    func disconnect() async

    /// Children of `container` (nil = the source root).
    func list(_ container: SourceItem?) async throws -> [SourceItem]

    /// Downloads the item identified by `uri` to `destination` (overwriting).
    func download(uri: String, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws

    /// A direct HTTP URL for the item, when the source offers one.
    func streamURL(for uri: String) async throws -> RemoteResource?

    func search(_ text: String) async throws -> [SourceItem]
    /// All tracks of a media server library (nil when unsupported).
    func libraryTracks(progress: @escaping @Sendable (Int, Int) -> Void) async throws -> [Track]?

    func upload(from localURL: URL, to container: SourceItem?, fileName: String) async throws
    func delete(_ item: SourceItem) async throws
    func rename(_ item: SourceItem, to newName: String) async throws
    func createFolder(named name: String, in container: SourceItem?) async throws
}

extension MusicSource {
    public func disconnect() async {}

    public func streamURL(for uri: String) async throws -> RemoteResource? { nil }

    public func search(_ text: String) async throws -> [SourceItem] {
        throw MuurError.unsupported("Search on \(config.kind.displayName)")
    }

    public func libraryTracks(progress: @escaping @Sendable (Int, Int) -> Void) async throws -> [Track]? { nil }

    public func upload(from localURL: URL, to container: SourceItem?, fileName: String) async throws {
        throw MuurError.unsupported("Uploading to \(config.kind.displayName)")
    }

    public func delete(_ item: SourceItem) async throws {
        throw MuurError.unsupported("Deleting on \(config.kind.displayName)")
    }

    public func rename(_ item: SourceItem, to newName: String) async throws {
        throw MuurError.unsupported("Renaming on \(config.kind.displayName)")
    }

    public func createFolder(named name: String, in container: SourceItem?) async throws {
        throw MuurError.unsupported("Creating folders on \(config.kind.displayName)")
    }

    /// Builds a library track for a file item (metadata from the file name; media servers fill `item.track`).
    public func makeTrack(for item: SourceItem, folderPath: String? = nil) -> Track {
        if var track = item.track {
            track.sourceID = config.id.uuidString
            if track.folderPath.isEmpty { track.folderPath = folderPath ?? config.name }
            return track
        }
        let parent = PathUtils.parent(item.path.hasPrefix("/") ? item.path : "/" + item.path)
        let relative = parent == "/" ? "" : parent
        var track = Track(sourceURI: item.uri, sourceID: config.id.uuidString,
                          folderPath: folderPath ?? (config.name + relative), fileName: item.name,
                          title: PathUtils.titleFromFileName(item.name), fileModified: item.modified, fileSize: item.size ?? 0)
        track.codec = MetadataReader.normalizeCodec(nil, fileExtension: PathUtils.fileExtension(item.name))
        return track
    }

    /// Recursively collects playable items below `container` (depth-limited).
    public func collectAudio(under container: SourceItem?, maxDepth: Int = 12, limit: Int = 50_000) async throws -> [SourceItem] {
        var result: [SourceItem] = []
        var stack: [(SourceItem?, Int)] = [(container, 0)]
        while let (current, depth) = stack.popLast() {
            try Task.checkCancellation()
            let children = try await list(current)
            for child in children {
                if child.kind == .audio {
                    result.append(child)
                    if result.count >= limit { return result }
                } else if child.kind == .folder && depth < maxDepth {
                    stack.append((child, depth + 1))
                }
            }
        }
        return result
    }
}

/// Shared helpers for path based sources.
enum SourcePaths {
    /// Normalized absolute path ("/a/b") for a base path option.
    static func root(_ basePath: String) -> String {
        var path = basePath.trimmingCharacters(in: .whitespaces)
        if path.isEmpty { return "/" }
        if !path.hasPrefix("/") { path = "/" + path }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    static func child(_ parent: String, _ name: String) -> String {
        parent == "/" ? "/" + name : parent + "/" + name
    }
}
