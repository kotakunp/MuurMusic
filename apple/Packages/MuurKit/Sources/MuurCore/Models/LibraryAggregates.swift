import Foundation

/// Album aggregate derived from tracks (grouped by album title + album artist).
public struct Album: Hashable, Identifiable, Sendable, Codable {
    /// Grouping key: `lowercased(album) + "\u{1F}" + lowercased(albumArtist)`.
    public var id: String
    public var title: String
    public var artist: String
    public var year: Int?
    public var genre: String
    public var trackCount: Int
    public var duration: Double
    public var artworkKey: String?
    public var maxSampleRate: Double
    public var maxBitDepth: Int
    public var codec: String
    public var dateAdded: Date
    public var playCount: Int

    public init(id: String, title: String, artist: String, year: Int?, genre: String, trackCount: Int, duration: Double,
                artworkKey: String?, maxSampleRate: Double, maxBitDepth: Int, codec: String, dateAdded: Date, playCount: Int) {
        self.id = id
        self.title = title
        self.artist = artist
        self.year = year
        self.genre = genre
        self.trackCount = trackCount
        self.duration = duration
        self.artworkKey = artworkKey
        self.maxSampleRate = maxSampleRate
        self.maxBitDepth = maxBitDepth
        self.codec = codec
        self.dateAdded = dateAdded
        self.playCount = playCount
    }

    public var displayTitle: String { title.isEmpty ? "Unknown Album" : title }
    public var displayArtist: String { artist.isEmpty ? "Unknown Artist" : artist }
    public var isHiRes: Bool { maxBitDepth > 16 || maxSampleRate > 48_000 }
}

/// Artist / album artist / genre / composer aggregate.
public struct LibraryGroup: Hashable, Identifiable, Sendable, Codable {
    public enum Kind: String, Codable, Sendable { case artist, albumArtist, genre, composer }
    public var id: String { kind.rawValue + ":" + name.lowercased() }
    public var kind: Kind
    public var name: String
    public var trackCount: Int
    public var albumCount: Int
    public var duration: Double
    public var artworkKey: String?

    public init(kind: Kind, name: String, trackCount: Int, albumCount: Int, duration: Double, artworkKey: String?) {
        self.kind = kind
        self.name = name
        self.trackCount = trackCount
        self.albumCount = albumCount
        self.duration = duration
        self.artworkKey = artworkKey
    }

    public var displayName: String {
        if !name.isEmpty { return name }
        switch kind {
        case .artist, .albumArtist: return "Unknown Artist"
        case .genre: return "Unknown Genre"
        case .composer: return "Unknown Composer"
        }
    }
}

public typealias Artist = LibraryGroup
public typealias Genre = LibraryGroup
public typealias Composer = LibraryGroup

/// A folder in the library's folder view.
public struct LibraryFolder: Hashable, Identifiable, Sendable, Codable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var trackCount: Int
    public var subfolderCount: Int

    public init(path: String, name: String, trackCount: Int, subfolderCount: Int) {
        self.path = path
        self.name = name
        self.trackCount = trackCount
        self.subfolderCount = subfolderCount
    }
}

public typealias Folder = LibraryFolder

/// Library-wide statistics.
public struct LibraryStats: Hashable, Sendable, Codable {
    public var trackCount: Int
    public var albumCount: Int
    public var artistCount: Int
    public var totalDuration: Double
    public var totalSize: Int64

    public init(trackCount: Int = 0, albumCount: Int = 0, artistCount: Int = 0, totalDuration: Double = 0, totalSize: Int64 = 0) {
        self.trackCount = trackCount
        self.albumCount = albumCount
        self.artistCount = artistCount
        self.totalDuration = totalDuration
        self.totalSize = totalSize
    }
}
