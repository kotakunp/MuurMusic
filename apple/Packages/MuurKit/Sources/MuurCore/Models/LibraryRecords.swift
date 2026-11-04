import Foundation
import GRDB

/// A saved position inside a track.
public struct Bookmark: Codable, Hashable, Identifiable, Sendable {
    public var id: Int64?
    public var trackId: Int64?
    public var sourceURI: String
    public var libraryKey: String
    public var title: String
    public var artist: String
    /// Position in seconds (relative to the track / CUE window start).
    public var position: Double
    public var note: String
    public var createdAt: Date

    public init(id: Int64? = nil, trackId: Int64?, sourceURI: String, libraryKey: String, title: String, artist: String,
                position: Double, note: String = "", createdAt: Date = Date()) {
        self.id = id
        self.trackId = trackId
        self.sourceURI = sourceURI
        self.libraryKey = libraryKey
        self.title = title
        self.artist = artist
        self.position = position
        self.note = note
        self.createdAt = createdAt
    }
}

extension Bookmark: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "bookmarks"
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// One play of a track.
public struct PlayHistoryEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: Int64?
    public var trackId: Int64?
    public var sourceURI: String
    public var libraryKey: String
    public var title: String
    public var artist: String
    public var album: String
    public var playedAt: Date
    /// Seconds actually listened.
    public var listenedSeconds: Double

    public init(id: Int64? = nil, trackId: Int64?, sourceURI: String, libraryKey: String, title: String, artist: String,
                album: String, playedAt: Date = Date(), listenedSeconds: Double) {
        self.id = id
        self.trackId = trackId
        self.sourceURI = sourceURI
        self.libraryKey = libraryKey
        self.title = title
        self.artist = artist
        self.album = album
        self.playedAt = playedAt
        self.listenedSeconds = listenedSeconds
    }
}

extension PlayHistoryEntry: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "play_history"
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// A folder watched by the library scanner.
public struct WatchedFolder: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// Last resolved path (informational; access goes through `bookmark`).
    public var path: String
    /// Security-scoped bookmark (nil for the app's own Documents folder).
    public var bookmark: Data?
    public var isAppDocuments: Bool
    public var enabled: Bool
    public var lastScan: Date?

    public init(id: String = UUID().uuidString, name: String, path: String, bookmark: Data?, isAppDocuments: Bool = false,
                enabled: Bool = true, lastScan: Date? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.bookmark = bookmark
        self.isAppDocuments = isAppDocuments
        self.enabled = enabled
        self.lastScan = lastScan
    }
}

extension WatchedFolder: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "watched_folders"
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }
}

// MARK: - Downloads

public enum DownloadState: String, Codable, Sendable, CaseIterable {
    case queued, downloading, paused, completed, failed
}

/// An offline download of one remote track.
public struct DownloadItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var sourceURI: String
    public var sourceID: String?
    public var title: String
    public var artist: String
    public var album: String
    public var state: DownloadState
    public var progress: Double
    public var bytesReceived: Int64
    public var bytesExpected: Int64
    /// Path relative to `AppPaths.downloadsDirectory` once completed.
    public var localPath: String?
    public var errorMessage: String?
    /// Album / playlist / folder name the download was requested for.
    public var groupName: String?
    public var trackId: Int64?
    public var retryCount: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, sourceURI: String, sourceID: String?, title: String, artist: String = "",
                album: String = "", state: DownloadState = .queued, progress: Double = 0, bytesReceived: Int64 = 0,
                bytesExpected: Int64 = 0, localPath: String? = nil, errorMessage: String? = nil, groupName: String? = nil,
                trackId: Int64? = nil, retryCount: Int = 0, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.sourceURI = sourceURI
        self.sourceID = sourceID
        self.title = title
        self.artist = artist
        self.album = album
        self.state = state
        self.progress = progress
        self.bytesReceived = bytesReceived
        self.bytesExpected = bytesExpected
        self.localPath = localPath
        self.errorMessage = errorMessage
        self.groupName = groupName
        self.trackId = trackId
        self.retryCount = retryCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension DownloadItem: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "downloads"
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }
}
