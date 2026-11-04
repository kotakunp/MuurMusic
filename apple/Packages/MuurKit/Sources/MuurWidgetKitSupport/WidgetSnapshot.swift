import Foundation

/// Shared constants for the App Group container used by the app and its widgets.
public enum MuurAppGroup {
    /// The App Group identifier shared by the app, widgets and CarPlay scene.
    public static let identifier = "group.app.muur.music"

    /// Returns the App Group container URL, or `nil` when the entitlement is missing.
    public static func containerURL(identifier: String = MuurAppGroup.identifier) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}

/// A single line of lyrics as stored in the widget snapshot.
public struct WidgetLyricLine: Codable, Hashable, Sendable {
    /// Time in seconds from the start of the track, `nil` for unsynced lyrics.
    public var time: Double?
    public var text: String

    public init(time: Double?, text: String) {
        self.time = time
        self.text = text
    }
}

/// A queue entry as shown by the Now Playing / queue widget.
public struct WidgetQueueItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var artist: String
    public var album: String
    /// File name of the artwork thumbnail inside `WidgetSharedStore.artworkDirectory`.
    public var artworkFileName: String?
    public var duration: Double

    public init(id: String, title: String, artist: String, album: String, artworkFileName: String?, duration: Double) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkFileName = artworkFileName
        self.duration = duration
    }
}

/// Now playing information written by the app for the widgets.
public struct WidgetNowPlaying: Codable, Hashable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var artworkFileName: String?
    public var duration: Double
    /// Elapsed playback time at `updatedAt`.
    public var elapsed: Double
    public var isPlaying: Bool
    public var playbackRate: Double
    public var updatedAt: Date
    /// Format badge, e.g. "FLAC 24/96".
    public var formatBadge: String?
    public var isFavorite: Bool

    public init(title: String, artist: String, album: String, artworkFileName: String?, duration: Double,
                elapsed: Double, isPlaying: Bool, playbackRate: Double = 1, updatedAt: Date = Date(),
                formatBadge: String? = nil, isFavorite: Bool = false) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkFileName = artworkFileName
        self.duration = duration
        self.elapsed = elapsed
        self.isPlaying = isPlaying
        self.playbackRate = playbackRate
        self.updatedAt = updatedAt
        self.formatBadge = formatBadge
        self.isFavorite = isFavorite
    }

    /// Estimated elapsed time at `date`, extrapolated while playing.
    public func estimatedElapsed(at date: Date) -> Double {
        guard isPlaying else { return elapsed }
        let value = elapsed + date.timeIntervalSince(updatedAt) * playbackRate
        return duration > 0 ? min(max(0, value), duration) : max(0, value)
    }
}

/// The complete snapshot read by widgets. Written atomically as JSON into the App Group container.
public struct WidgetSnapshot: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var nowPlaying: WidgetNowPlaying?
    public var upNext: [WidgetQueueItem]
    public var recentlyPlayed: [WidgetQueueItem]
    /// Lyrics of the current track (synced lines carry a time).
    public var lyrics: [WidgetLyricLine]
    public var lyricsAreSynced: Bool
    /// Accent color as a hex string (e.g. "#FFB23F").
    public var accentHex: String
    /// `true` when a restorable queue exists (used by the Resume widget).
    public var canResume: Bool
    public var updatedAt: Date

    public init(version: Int = WidgetSnapshot.currentVersion, nowPlaying: WidgetNowPlaying? = nil,
                upNext: [WidgetQueueItem] = [], recentlyPlayed: [WidgetQueueItem] = [],
                lyrics: [WidgetLyricLine] = [], lyricsAreSynced: Bool = false, accentHex: String = "#FFB23F",
                canResume: Bool = false, updatedAt: Date = Date()) {
        self.version = version
        self.nowPlaying = nowPlaying
        self.upNext = upNext
        self.recentlyPlayed = recentlyPlayed
        self.lyrics = lyrics
        self.lyricsAreSynced = lyricsAreSynced
        self.accentHex = accentHex
        self.canResume = canResume
        self.updatedAt = updatedAt
    }

    public static let empty = WidgetSnapshot()

    /// Index of the synced lyric line active at `time`, or `nil`.
    public func lyricIndex(at time: Double) -> Int? {
        guard lyricsAreSynced else { return nil }
        var result: Int?
        for (index, line) in lyrics.enumerated() {
            guard let lineTime = line.time else { continue }
            if lineTime <= time { result = index } else { break }
        }
        return result
    }
}

/// Reads and writes `WidgetSnapshot` and artwork thumbnails in the App Group container.
public struct WidgetSharedStore: Sendable {
    public static let snapshotFileName = "widget-snapshot.json"
    public static let artworkDirectoryName = "WidgetArtwork"

    public let appGroupIdentifier: String

    public init(appGroupIdentifier: String = MuurAppGroup.identifier) {
        self.appGroupIdentifier = appGroupIdentifier
    }

    /// Root directory used inside the App Group container (falls back to Caches without the entitlement).
    public var rootDirectory: URL {
        if let container = MuurAppGroup.containerURL(identifier: appGroupIdentifier) {
            return container.appendingPathComponent("MuurShared", isDirectory: true)
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("MuurShared", isDirectory: true)
    }

    public var snapshotURL: URL {
        rootDirectory.appendingPathComponent(Self.snapshotFileName)
    }

    public var artworkDirectory: URL {
        rootDirectory.appendingPathComponent(Self.artworkDirectoryName, isDirectory: true)
    }

    /// URL of an artwork thumbnail file referenced by a snapshot.
    public func artworkURL(fileName: String?) -> URL? {
        guard let fileName, !fileName.isEmpty else { return nil }
        let url = artworkDirectory.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Reads the last snapshot written by the app. Returns `.empty` if none exists.
    public func read() -> WidgetSnapshot {
        guard let data = try? Data(contentsOf: snapshotURL) else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(WidgetSnapshot.self, from: data)) ?? .empty
    }

    /// Writes a snapshot atomically.
    public func write(_ snapshot: WidgetSnapshot) throws {
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(snapshot)
        try data.write(to: snapshotURL, options: [.atomic])
    }

    /// Stores (small) artwork thumbnail data under `fileName` and returns the file name.
    @discardableResult
    public func writeArtwork(_ data: Data, fileName: String) throws -> String {
        try FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        let url = artworkDirectory.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: [.atomic])
        }
        return fileName
    }

    /// Removes artwork files not referenced by `keep`.
    public func pruneArtwork(keeping keep: Set<String>) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: artworkDirectory.path) else { return }
        for file in files where !keep.contains(file) {
            try? fm.removeItem(at: artworkDirectory.appendingPathComponent(file))
        }
    }
}
