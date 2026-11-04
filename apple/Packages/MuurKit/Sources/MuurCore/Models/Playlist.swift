import Foundation
import GRDB

/// A normal or smart playlist.
public struct Playlist: Codable, Hashable, Identifiable, Sendable {
    public var id: Int64?
    public var name: String
    public var isSmart: Bool
    /// Smart playlist definition (`muur-smart` JSON) for smart playlists.
    public var smartDefinition: SmartPlaylistDefinition?
    public var notes: String
    public var artworkKey: String?
    public var sortIndex: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: Int64? = nil, name: String, isSmart: Bool = false, smartDefinition: SmartPlaylistDefinition? = nil,
                notes: String = "", artworkKey: String? = nil, sortIndex: Int = 0, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.isSmart = isSmart
        self.smartDefinition = smartDefinition
        self.notes = notes
        self.artworkKey = artworkKey
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension Playlist: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "playlists"
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// A playlist entry. Items keep the source URI and display metadata so they survive library rescans.
public struct PlaylistItem: Codable, Hashable, Identifiable, Sendable {
    public var id: Int64?
    public var playlistId: Int64
    public var trackId: Int64?
    public var sourceURI: String
    public var libraryKey: String
    public var title: String
    public var artist: String
    public var duration: Double
    public var position: Int

    public init(id: Int64? = nil, playlistId: Int64, trackId: Int64?, sourceURI: String, libraryKey: String,
                title: String, artist: String, duration: Double, position: Int) {
        self.id = id
        self.playlistId = playlistId
        self.trackId = trackId
        self.sourceURI = sourceURI
        self.libraryKey = libraryKey
        self.title = title
        self.artist = artist
        self.duration = duration
        self.position = position
    }
}

extension PlaylistItem: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "playlist_items"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// Playlist with its resolved tracks (items whose track is no longer in the library get a placeholder track).
public struct PlaylistWithTracks: Hashable, Sendable {
    public var playlist: Playlist
    public var items: [PlaylistItem]
    public var tracks: [Track]

    public init(playlist: Playlist, items: [PlaylistItem], tracks: [Track]) {
        self.playlist = playlist
        self.items = items
        self.tracks = tracks
    }
}

// MARK: - Smart playlists (`*.muursmart.json`)

public enum SmartRuleField: String, Codable, CaseIterable, Sendable {
    case genre, artist, albumArtist, album, composer, year, rating, playCount, dateAdded, format, bitDepth, sampleRate, duration
    case title, favorite, lastPlayed, bpm, bitrate

    public var isNumeric: Bool {
        switch self {
        case .year, .rating, .playCount, .bitDepth, .sampleRate, .duration, .bpm, .bitrate, .favorite: return true
        case .dateAdded, .lastPlayed: return true
        default: return false
        }
    }

    public var isDate: Bool { self == .dateAdded || self == .lastPlayed }
}

public enum SmartRuleOperator: String, Codable, CaseIterable, Sendable {
    case `is`, isNot, contains, startsWith, gt, lt, between, inLast
}

public struct SmartRule: Codable, Hashable, Sendable {
    public var field: SmartRuleField
    public var op: SmartRuleOperator
    public var value: JSONValue
    public var value2: JSONValue?

    public init(field: SmartRuleField, op: SmartRuleOperator, value: JSONValue, value2: JSONValue? = nil) {
        self.field = field
        self.op = op
        self.value = value
        self.value2 = value2
    }

    private enum CodingKeys: String, CodingKey { case field, op, value, value2 }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        field = try container.decode(SmartRuleField.self, forKey: .field)
        op = try container.decode(SmartRuleOperator.self, forKey: .op)
        value = try container.decodeIfPresent(JSONValue.self, forKey: .value) ?? .null
        value2 = try container.decodeIfPresent(JSONValue.self, forKey: .value2)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(field, forKey: .field)
        try container.encode(op, forKey: .op)
        try container.encode(value, forKey: .value)
        try container.encodeIfPresent(value2, forKey: .value2)
    }
}

public enum SmartMatch: String, Codable, Sendable { case all, any }

public struct SmartPlaylistDefinition: Codable, Hashable, Sendable {
    public var format: String
    public var version: Int
    public var name: String
    public var match: SmartMatch
    public var rules: [SmartRule]
    /// A `TrackSortField` raw value; prefix "-" for descending (e.g. "-playCount").
    public var sort: String
    /// 0 = no limit.
    public var limit: Int

    public init(name: String, match: SmartMatch = .all, rules: [SmartRule] = [], sort: String = "title", limit: Int = 0) {
        self.format = "muur-smart"
        self.version = 1
        self.name = name
        self.match = match
        self.rules = rules
        self.sort = sort
        self.limit = limit
    }

    private enum CodingKeys: String, CodingKey { case format, version, name, match, rules, sort, limit }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decodeIfPresent(String.self, forKey: .format) ?? "muur-smart"
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Smart Playlist"
        match = try container.decodeIfPresent(SmartMatch.self, forKey: .match) ?? .all
        rules = try container.decodeIfPresent([SmartRule].self, forKey: .rules) ?? []
        sort = try container.decodeIfPresent(String.self, forKey: .sort) ?? "title"
        limit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? 0
    }
}
