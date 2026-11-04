import Foundation
import GRDB

/// A song in the library. Local files, downloaded remote files and remote (streamed) tracks all use this
/// type; CUE sheet entries become virtual tracks that share the audio file's `sourceURI` and carry a
/// `cueStart`/`cueEnd` window in seconds.
public struct Track: Codable, Hashable, Identifiable, Sendable {
    public var id: Int64?
    /// Unique key: the source URI, plus `#cue=<n>` for CUE virtual tracks.
    public var libraryKey: String
    /// Source URI per SHARED_FORMATS (`file:///…`, `smb://…`, `dropbox://<sourceId>/…`, …).
    public var sourceURI: String
    /// Configured source UUID string for remote tracks, `nil` for local files.
    public var sourceID: String?
    /// Display path of the containing folder (used by folder browsing).
    public var folderPath: String
    public var fileName: String

    public var title: String
    public var artist: String
    public var album: String
    public var albumArtist: String
    public var genre: String
    public var composer: String
    public var year: Int?
    public var trackNumber: Int?
    public var trackTotal: Int?
    public var discNumber: Int?
    public var discTotal: Int?
    public var bpm: Int?
    public var comment: String
    /// Embedded (unsynced or LRC) lyrics text read from tags.
    public var lyrics: String?
    public var hasLyrics: Bool
    /// User notes (not written to tags).
    public var notes: String

    /// 0...5 stars.
    public var rating: Int
    public var playCount: Int
    public var skipCount: Int
    public var lastPlayed: Date?
    public var dateAdded: Date
    public var fileModified: Date?
    public var favorite: Bool

    /// Duration in seconds (for CUE tracks: the window length).
    public var duration: Double
    /// Bitrate in kbit/s.
    public var bitrate: Int
    public var sampleRate: Double
    public var bitDepth: Int
    public var channels: Int
    /// Codec / container format name, e.g. "FLAC", "ALAC", "MP3", "DSD".
    public var codec: String
    public var fileSize: Int64

    public var cueStart: Double?
    public var cueEnd: Double?
    public var cueSheetURI: String?

    /// Key into `ArtworkCache`.
    public var artworkKey: String?
    public var replayGainTrackGain: Double?
    public var replayGainTrackPeak: Double?
    public var replayGainAlbumGain: Double?
    public var replayGainAlbumPeak: Double?
    public var musicBrainzRecordingID: String?
    public var musicBrainzReleaseID: String?

    public init(id: Int64? = nil, libraryKey: String? = nil, sourceURI: String, sourceID: String? = nil,
                folderPath: String = "", fileName: String = "", title: String, artist: String = "", album: String = "",
                albumArtist: String = "", genre: String = "", composer: String = "", year: Int? = nil,
                trackNumber: Int? = nil, trackTotal: Int? = nil, discNumber: Int? = nil, discTotal: Int? = nil,
                bpm: Int? = nil, comment: String = "", lyrics: String? = nil, hasLyrics: Bool = false, notes: String = "",
                rating: Int = 0, playCount: Int = 0, skipCount: Int = 0, lastPlayed: Date? = nil,
                dateAdded: Date = Date(), fileModified: Date? = nil, favorite: Bool = false, duration: Double = 0,
                bitrate: Int = 0, sampleRate: Double = 0, bitDepth: Int = 0, channels: Int = 0, codec: String = "",
                fileSize: Int64 = 0, cueStart: Double? = nil, cueEnd: Double? = nil, cueSheetURI: String? = nil,
                artworkKey: String? = nil, replayGainTrackGain: Double? = nil, replayGainTrackPeak: Double? = nil,
                replayGainAlbumGain: Double? = nil, replayGainAlbumPeak: Double? = nil,
                musicBrainzRecordingID: String? = nil, musicBrainzReleaseID: String? = nil) {
        self.id = id
        self.libraryKey = libraryKey ?? sourceURI
        self.sourceURI = sourceURI
        self.sourceID = sourceID
        self.folderPath = folderPath
        self.fileName = fileName
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.genre = genre
        self.composer = composer
        self.year = year
        self.trackNumber = trackNumber
        self.trackTotal = trackTotal
        self.discNumber = discNumber
        self.discTotal = discTotal
        self.bpm = bpm
        self.comment = comment
        self.lyrics = lyrics
        self.hasLyrics = hasLyrics
        self.notes = notes
        self.rating = rating
        self.playCount = playCount
        self.skipCount = skipCount
        self.lastPlayed = lastPlayed
        self.dateAdded = dateAdded
        self.fileModified = fileModified
        self.favorite = favorite
        self.duration = duration
        self.bitrate = bitrate
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channels = channels
        self.codec = codec
        self.fileSize = fileSize
        self.cueStart = cueStart
        self.cueEnd = cueEnd
        self.cueSheetURI = cueSheetURI
        self.artworkKey = artworkKey
        self.replayGainTrackGain = replayGainTrackGain
        self.replayGainTrackPeak = replayGainTrackPeak
        self.replayGainAlbumGain = replayGainAlbumGain
        self.replayGainAlbumPeak = replayGainAlbumPeak
        self.musicBrainzRecordingID = musicBrainzRecordingID
        self.musicBrainzReleaseID = musicBrainzReleaseID
    }

    // MARK: Derived values

    public var isLocal: Bool { sourceURI.hasPrefix("file:") }
    public var isCueTrack: Bool { cueStart != nil }
    public var displayArtist: String { artist.isEmpty ? (albumArtist.isEmpty ? "Unknown Artist" : albumArtist) : artist }
    public var displayAlbumArtist: String { albumArtist.isEmpty ? displayArtist : albumArtist }
    public var displayAlbum: String { album.isEmpty ? "Unknown Album" : album }
    public var displayTitle: String { title.isEmpty ? PathUtils.titleFromFileName(fileName) : title }

    /// `true` for lossless formats at > 16 bit or > 48 kHz.
    public var isHiRes: Bool { bitDepth > 16 || sampleRate > 48_000 || codec.uppercased().contains("DSD") }

    /// Short format description such as "FLAC 24/96" or "MP3 320".
    public var formatBadge: String {
        let codecName = codec.isEmpty ? PathUtils.fileExtension(fileName).uppercased() : codec
        let upper = codecName.uppercased()
        if upper.contains("DSD") || upper == "DSF" || upper == "DSDIFF" {
            let multiple = sampleRate > 0 ? Int((sampleRate / 44_100).rounded()) : 64
            return "DSD\(multiple)"
        }
        if bitDepth > 0 && sampleRate > 0 {
            let khz = sampleRate / 1000
            let rateText = khz == khz.rounded() ? String(Int(khz)) : String(format: "%.1f", khz)
            return "\(codecName) \(bitDepth)/\(rateText)"
        }
        if bitrate > 0 { return "\(codecName) \(bitrate)" }
        return codecName
    }

    /// Stable identity used for de-duplication in queues and widgets.
    public var stableID: String { libraryKey }
}

extension Track: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "tracks"

    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSince1970
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Library columns usable for sorting (FEATURES §3).
public enum TrackSortField: String, Codable, CaseIterable, Sendable {
    case title, album, artist, albumArtist, genre, composer, rating, year, bpm, playCount, bitrate, duration, dateAdded
    case lastPlayed, trackNumber, fileName

    /// SQL ORDER BY expression (without direction).
    public var sqlExpression: String {
        switch self {
        case .title: return "tracks.title COLLATE NOCASE"
        case .album: return "tracks.album COLLATE NOCASE, tracks.discNumber, tracks.trackNumber"
        case .artist: return "tracks.artist COLLATE NOCASE, tracks.album COLLATE NOCASE, tracks.discNumber, tracks.trackNumber"
        case .albumArtist: return "CASE WHEN tracks.albumArtist = '' THEN tracks.artist ELSE tracks.albumArtist END COLLATE NOCASE, tracks.album COLLATE NOCASE, tracks.discNumber, tracks.trackNumber"
        case .genre: return "tracks.genre COLLATE NOCASE"
        case .composer: return "tracks.composer COLLATE NOCASE"
        case .rating: return "tracks.rating"
        case .year: return "tracks.year"
        case .bpm: return "tracks.bpm"
        case .playCount: return "tracks.playCount"
        case .bitrate: return "tracks.bitrate"
        case .duration: return "tracks.duration"
        case .dateAdded: return "tracks.dateAdded"
        case .lastPlayed: return "tracks.lastPlayed"
        case .trackNumber: return "tracks.discNumber, tracks.trackNumber"
        case .fileName: return "tracks.fileName COLLATE NOCASE"
        }
    }

    public var displayName: String {
        switch self {
        case .title: return "Title"
        case .album: return "Album"
        case .artist: return "Artist"
        case .albumArtist: return "Album Artist"
        case .genre: return "Genre"
        case .composer: return "Composer"
        case .rating: return "Rating"
        case .year: return "Year"
        case .bpm: return "BPM"
        case .playCount: return "Play Count"
        case .bitrate: return "Bitrate"
        case .duration: return "Length"
        case .dateAdded: return "Date Added"
        case .lastPlayed: return "Last Played"
        case .trackNumber: return "Track Number"
        case .fileName: return "File Name"
        }
    }
}

public struct TrackSort: Codable, Hashable, Sendable {
    public var field: TrackSortField
    public var ascending: Bool

    public init(field: TrackSortField = .title, ascending: Bool = true) {
        self.field = field
        self.ascending = ascending
    }

    public var orderSQL: String {
        let direction = ascending ? "ASC" : "DESC"
        let parts = field.sqlExpression.components(separatedBy: ", ")
        return (parts.map { "\($0) \(direction)" } + ["tracks.id ASC"]).joined(separator: ", ")
    }
}
