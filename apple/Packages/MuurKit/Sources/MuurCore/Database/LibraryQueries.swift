import Foundation
import GRDB

/// Track filters understood by `LibraryQueries.tracks`.
public enum TrackFilter: Hashable, Sendable {
    case all
    case album(title: String, artist: String)
    case group(LibraryGroup.Kind, String)
    /// Tracks in a folder (display path, see `Track.folderPath`), optionally including subfolders.
    case folder(String, recursive: Bool)
    case favorites
    case source(String)
    case ids([Int64])
    case localOnly
    case remoteOnly
    case hiRes
    case withLyrics
    case unplayed
    /// Tracks with a completed offline download.
    case downloaded
    /// Local files plus downloaded remote tracks (what offline mode can play without the audio cache).
    case availableOffline

    func clause() -> (String, [(any DatabaseValueConvertible)?]) {
        switch self {
        case .all:
            return ("1", [])
        case .album(let title, let artist):
            return ("tracks.album = ? COLLATE NOCASE AND \(LibraryQueries.albumArtistExpression) = ? COLLATE NOCASE", [title, artist])
        case .group(let kind, let name):
            return ("\(LibraryQueries.column(for: kind)) = ? COLLATE NOCASE", [name])
        case .folder(let path, let recursive):
            if recursive {
                return ("(tracks.folderPath = ? OR tracks.folderPath LIKE ? ESCAPE '\\')", [path, LibraryQueries.likeEscape(path) + "/%"])
            }
            return ("tracks.folderPath = ?", [path])
        case .favorites:
            return ("tracks.favorite = 1", [])
        case .source(let id):
            return ("tracks.sourceID = ?", [id])
        case .ids(let ids):
            if ids.isEmpty { return ("0", []) }
            return ("tracks.id IN (\(Array(repeating: "?", count: ids.count).joined(separator: ",")))", ids.map { $0 as (any DatabaseValueConvertible)? })
        case .localOnly:
            return ("tracks.sourceURI LIKE 'file:%'", [])
        case .remoteOnly:
            return ("tracks.sourceURI NOT LIKE 'file:%'", [])
        case .hiRes:
            return ("(tracks.bitDepth > 16 OR tracks.sampleRate > 48000 OR tracks.codec LIKE 'DSD%')", [])
        case .withLyrics:
            return ("tracks.hasLyrics = 1", [])
        case .unplayed:
            return ("tracks.playCount = 0", [])
        case .downloaded:
            return ("tracks.sourceURI IN (SELECT sourceURI FROM downloads WHERE state = 'completed')", [])
        case .availableOffline:
            return ("(tracks.sourceURI LIKE 'file:%' OR tracks.sourceURI IN (SELECT sourceURI FROM downloads WHERE state = 'completed'))", [])
        }
    }
}

/// Album list ordering.
public enum AlbumSort: String, Codable, CaseIterable, Sendable {
    case title, artist, year, dateAdded, playCount

    var orderSQL: String {
        switch self {
        case .title: return "title COLLATE NOCASE ASC, artist COLLATE NOCASE ASC"
        case .artist: return "artist COLLATE NOCASE ASC, year ASC, title COLLATE NOCASE ASC"
        case .year: return "year DESC, artist COLLATE NOCASE ASC, title COLLATE NOCASE ASC"
        case .dateAdded: return "dateAdded DESC, title COLLATE NOCASE ASC"
        case .playCount: return "playCount DESC, title COLLATE NOCASE ASC"
        }
    }

    public var displayName: String {
        switch self {
        case .title: return "Title"
        case .artist: return "Artist"
        case .year: return "Year"
        case .dateAdded: return "Date Added"
        case .playCount: return "Most Played"
        }
    }
}

/// Album filters.
public enum AlbumFilter: Hashable, Sendable {
    case all
    /// Albums containing tracks by the artist (track artist or album artist).
    case artist(String)
    case albumArtist(String)
    case genre(String)
    case composer(String)
    case search(String)
}

/// Combined search results.
public struct LibrarySearchResults: Hashable, Sendable {
    public var tracks: [Track]
    public var albums: [Album]
    public var artists: [LibraryGroup]
    public var playlists: [Playlist]

    public init(tracks: [Track] = [], albums: [Album] = [], artists: [LibraryGroup] = [], playlists: [Playlist] = []) {
        self.tracks = tracks
        self.albums = albums
        self.artists = artists
        self.playlists = playlists
    }

    public var isEmpty: Bool { tracks.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty }
}

extension Album: FetchableRecord {
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }
}

/// Synchronous query functions taking a GRDB `Database`. They are the building blocks of
/// `LibraryRepository` and can be used inside `ValueObservation.tracking { db in ... }`.
public enum LibraryQueries {
    static let albumArtistExpression = "(CASE WHEN tracks.albumArtist <> '' THEN tracks.albumArtist ELSE tracks.artist END)"

    static func column(for kind: LibraryGroup.Kind) -> String {
        switch kind {
        case .artist: return "tracks.artist"
        case .albumArtist: return albumArtistExpression
        case .genre: return "tracks.genre"
        case .composer: return "tracks.composer"
        }
    }

    /// Escapes `%`, `_` and `\` for `LIKE ... ESCAPE '\'`.
    public static func likeEscape(_ string: String) -> String {
        string.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: Tracks

    public static func tracks(_ db: Database, filter: TrackFilter = .all, sort: TrackSort = TrackSort(), limit: Int? = nil) throws -> [Track] {
        let (whereSQL, args) = filter.clause()
        var sql = "SELECT tracks.* FROM tracks WHERE \(whereSQL) ORDER BY \(sort.orderSQL)"
        if let limit, limit > 0 { sql += " LIMIT \(limit)" }
        return try Track.fetchAll(db, sql: sql, arguments: StatementArguments(args))
    }

    public static func trackCount(_ db: Database, filter: TrackFilter = .all) throws -> Int {
        let (whereSQL, args) = filter.clause()
        return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks WHERE \(whereSQL)", arguments: StatementArguments(args)) ?? 0
    }

    public static func track(_ db: Database, id: Int64) throws -> Track? {
        try Track.fetchOne(db, sql: "SELECT * FROM tracks WHERE id = ?", arguments: [id])
    }

    public static func track(_ db: Database, libraryKey: String) throws -> Track? {
        try Track.fetchOne(db, sql: "SELECT * FROM tracks WHERE libraryKey = ?", arguments: [libraryKey])
    }

    public static func tracks(_ db: Database, sourceURI: String) throws -> [Track] {
        try Track.fetchAll(db, sql: "SELECT * FROM tracks WHERE sourceURI = ? ORDER BY cueStart", arguments: [sourceURI])
    }

    /// Tracks for the given ids, in the order of `ids` (missing ids are skipped).
    public static func tracks(_ db: Database, orderedIDs ids: [Int64]) throws -> [Track] {
        guard !ids.isEmpty else { return [] }
        var byID: [Int64: Track] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 500) {
            let slice = Array(ids[chunk..<min(chunk + 500, ids.count)])
            for track in try tracks(db, filter: .ids(slice)) {
                if let id = track.id { byID[id] = track }
            }
        }
        return ids.compactMap { byID[$0] }
    }

    public static func recentlyAdded(_ db: Database, limit: Int = 50) throws -> [Track] {
        try Track.fetchAll(db, sql: "SELECT * FROM tracks ORDER BY dateAdded DESC, id DESC LIMIT ?", arguments: [limit])
    }

    public static func recentlyPlayed(_ db: Database, limit: Int = 50) throws -> [Track] {
        try Track.fetchAll(db, sql: "SELECT * FROM tracks WHERE lastPlayed IS NOT NULL ORDER BY lastPlayed DESC LIMIT ?", arguments: [limit])
    }

    public static func mostPlayed(_ db: Database, limit: Int = 50) throws -> [Track] {
        try Track.fetchAll(db, sql: "SELECT * FROM tracks WHERE playCount > 0 ORDER BY playCount DESC, lastPlayed DESC LIMIT ?", arguments: [limit])
    }

    public static func randomTracks(_ db: Database, limit: Int = 100, filter: TrackFilter = .all) throws -> [Track] {
        let (whereSQL, args) = filter.clause()
        return try Track.fetchAll(db, sql: "SELECT * FROM tracks WHERE \(whereSQL) ORDER BY RANDOM() LIMIT \(max(1, limit))",
                                  arguments: StatementArguments(args))
    }

    // MARK: Albums & groups

    public static func albums(_ db: Database, filter: AlbumFilter = .all, sort: AlbumSort = .title, limit: Int? = nil) throws -> [Album] {
        var whereSQL = "1"
        var args: [(any DatabaseValueConvertible)?] = []
        switch filter {
        case .all:
            break
        case .artist(let name):
            whereSQL = "(tracks.artist = ? COLLATE NOCASE OR \(albumArtistExpression) = ? COLLATE NOCASE)"
            args = [name, name]
        case .albumArtist(let name):
            whereSQL = "\(albumArtistExpression) = ? COLLATE NOCASE"
            args = [name]
        case .genre(let name):
            whereSQL = "tracks.genre = ? COLLATE NOCASE"
            args = [name]
        case .composer(let name):
            whereSQL = "tracks.composer = ? COLLATE NOCASE"
            args = [name]
        case .search(let text):
            let pattern = "%" + likeEscape(text) + "%"
            whereSQL = "(tracks.album LIKE ? ESCAPE '\\' OR \(albumArtistExpression) LIKE ? ESCAPE '\\')"
            args = [pattern, pattern]
        }
        var sql = """
            SELECT lower(min(tracks.album)) || char(31) || lower(min(\(albumArtistExpression))) AS id,
                   min(tracks.album) AS title,
                   min(\(albumArtistExpression)) AS artist,
                   max(tracks.year) AS year,
                   max(tracks.genre) AS genre,
                   count(*) AS trackCount,
                   sum(tracks.duration) AS duration,
                   max(tracks.artworkKey) AS artworkKey,
                   max(tracks.sampleRate) AS maxSampleRate,
                   max(tracks.bitDepth) AS maxBitDepth,
                   max(tracks.codec) AS codec,
                   min(tracks.dateAdded) AS dateAdded,
                   sum(tracks.playCount) AS playCount
            FROM tracks
            WHERE \(whereSQL)
            GROUP BY tracks.album COLLATE NOCASE, \(albumArtistExpression) COLLATE NOCASE
            ORDER BY \(sort.orderSQL)
            """
        if let limit, limit > 0 { sql += " LIMIT \(limit)" }
        return try Album.fetchAll(db, sql: sql, arguments: StatementArguments(args))
    }

    public static func album(_ db: Database, title: String, artist: String) throws -> Album? {
        let candidates = try albums(db, filter: .albumArtist(artist), sort: .title, limit: nil)
        return candidates.first { $0.title.caseInsensitiveCompare(title) == .orderedSame }
    }

    /// Tracks of an album in disc / track order.
    public static func tracks(_ db: Database, album: Album) throws -> [Track] {
        try tracks(db, filter: .album(title: album.title, artist: album.artist), sort: TrackSort(field: .trackNumber))
    }

    public static func groups(_ db: Database, kind: LibraryGroup.Kind, search: String? = nil) throws -> [LibraryGroup] {
        let columnSQL = column(for: kind)
        var whereSQL = "1"
        var args: [(any DatabaseValueConvertible)?] = []
        if let search, !search.isEmpty {
            whereSQL = "\(columnSQL) LIKE ? ESCAPE '\\'"
            args = ["%" + likeEscape(search) + "%"]
        }
        let sql = """
            SELECT min(\(columnSQL)) AS name, count(*) AS trackCount,
                   count(DISTINCT lower(tracks.album)) AS albumCount, sum(tracks.duration) AS duration,
                   max(tracks.artworkKey) AS artworkKey
            FROM tracks
            WHERE \(whereSQL)
            GROUP BY \(columnSQL) COLLATE NOCASE
            ORDER BY (min(\(columnSQL)) = '') ASC, min(\(columnSQL)) COLLATE NOCASE ASC
            """
        return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map { row in
            LibraryGroup(kind: kind, name: row["name"] ?? "", trackCount: row["trackCount"] ?? 0,
                         albumCount: row["albumCount"] ?? 0, duration: row["duration"] ?? 0, artworkKey: row["artworkKey"])
        }
    }

    // MARK: Folders

    /// Child folders of `parent` ("" for the top level) with recursive track counts.
    public static func folders(_ db: Database, parent: String = "") throws -> [LibraryFolder] {
        let rows = try Row.fetchAll(db, sql: "SELECT folderPath, count(*) AS c FROM tracks GROUP BY folderPath")
        let prefix = parent.isEmpty ? "" : parent + "/"
        var counts: [String: Int] = [:]
        var grandchildren: [String: Set<String>] = [:]
        for row in rows {
            let path: String = row["folderPath"] ?? ""
            let count: Int = row["c"] ?? 0
            guard !path.isEmpty, path.hasPrefix(prefix), path != parent else { continue }
            let remainder = path.dropFirst(prefix.count)
            let components = remainder.split(separator: "/", omittingEmptySubsequences: true)
            guard let first = components.first else { continue }
            let childPath = prefix + first
            counts[childPath, default: 0] += count
            if components.count > 1 {
                grandchildren[childPath, default: []].insert(String(components[1]))
            }
        }
        return counts.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { path in
            LibraryFolder(path: path, name: PathUtils.lastComponent(path), trackCount: counts[path] ?? 0,
                          subfolderCount: grandchildren[path]?.count ?? 0)
        }
    }

    // MARK: Search

    /// Full-text search over title / artist / album / album artist / genre / composer / file name.
    public static func searchTracks(_ db: Database, _ text: String, limit: Int = 200) throws -> [Track] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if let pattern = FTS5Pattern(matchingAllPrefixesIn: trimmed) {
            let results = try Track.fetchAll(db, sql: """
                SELECT tracks.* FROM tracks_fts JOIN tracks ON tracks.id = tracks_fts.rowid
                WHERE tracks_fts MATCH ? ORDER BY bm25(tracks_fts, 10.0, 6.0, 4.0, 4.0, 1.0, 2.0, 1.0) LIMIT ?
                """, arguments: [pattern, limit])
            if !results.isEmpty { return results }
        }
        let like = "%" + likeEscape(trimmed) + "%"
        return try Track.fetchAll(db, sql: """
            SELECT * FROM tracks WHERE title LIKE ?1 ESCAPE '\\' OR artist LIKE ?1 ESCAPE '\\' OR album LIKE ?1 ESCAPE '\\'
                OR fileName LIKE ?1 ESCAPE '\\' ORDER BY title COLLATE NOCASE LIMIT ?2
            """, arguments: [like, limit])
    }

    public static func search(_ db: Database, _ text: String, limit: Int = 100) throws -> LibrarySearchResults {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return LibrarySearchResults() }
        let foundTracks = try searchTracks(db, trimmed, limit: limit)
        let foundAlbums = try albums(db, filter: .search(trimmed), limit: limit)
        let foundArtists = try groups(db, kind: .artist, search: trimmed).prefix(limit)
        let foundPlaylists = try Playlist.fetchAll(db, sql: "SELECT * FROM playlists WHERE name LIKE ? ESCAPE '\\' ORDER BY name COLLATE NOCASE",
                                              arguments: ["%" + likeEscape(trimmed) + "%"])
        return LibrarySearchResults(tracks: foundTracks, albums: foundAlbums, artists: Array(foundArtists), playlists: foundPlaylists)
    }

    // MARK: Stats & history

    public static func stats(_ db: Database) throws -> LibraryStats {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT count(*) AS tracks, coalesce(sum(duration), 0) AS duration, coalesce(sum(fileSize), 0) AS size,
                   count(DISTINCT lower(album) || char(31) || lower(CASE WHEN albumArtist <> '' THEN albumArtist ELSE artist END)) AS albums,
                   count(DISTINCT lower(artist)) AS artists
            FROM tracks
            """) else { return LibraryStats() }
        return LibraryStats(trackCount: row["tracks"] ?? 0, albumCount: row["albums"] ?? 0, artistCount: row["artists"] ?? 0,
                            totalDuration: row["duration"] ?? 0, totalSize: row["size"] ?? 0)
    }

    public static func history(_ db: Database, limit: Int = 200) throws -> [PlayHistoryEntry] {
        try PlayHistoryEntry.fetchAll(db, sql: "SELECT * FROM play_history ORDER BY playedAt DESC LIMIT ?", arguments: [limit])
    }

    public static func bookmarks(_ db: Database, libraryKey: String? = nil) throws -> [Bookmark] {
        if let libraryKey {
            return try Bookmark.fetchAll(db, sql: "SELECT * FROM bookmarks WHERE libraryKey = ? ORDER BY position", arguments: [libraryKey])
        }
        return try Bookmark.fetchAll(db, sql: "SELECT * FROM bookmarks ORDER BY createdAt DESC")
    }

    public static func sources(_ db: Database) throws -> [SourceConfig] {
        try SourceConfig.fetchAll(db, sql: "SELECT * FROM sources ORDER BY sortIndex, name COLLATE NOCASE")
    }

    public static func watchedFolders(_ db: Database) throws -> [WatchedFolder] {
        try WatchedFolder.fetchAll(db, sql: "SELECT * FROM watched_folders ORDER BY name COLLATE NOCASE")
    }

    public static func downloads(_ db: Database) throws -> [DownloadItem] {
        try DownloadItem.fetchAll(db, sql: "SELECT * FROM downloads ORDER BY createdAt DESC")
    }

    // MARK: Mutations

    /// Inserts or updates a track identified by `libraryKey`. User data (rating, play counts, favorite,
    /// notes, date added, last played) of an existing row is preserved; scanned metadata is replaced.
    @discardableResult
    public static func upsert(_ db: Database, _ track: Track) throws -> Track {
        var record = track
        if let existing = try self.track(db, libraryKey: track.libraryKey) {
            record.id = existing.id
            record.rating = track.rating > 0 ? track.rating : existing.rating
            record.playCount = max(existing.playCount, track.playCount)
            record.skipCount = max(existing.skipCount, track.skipCount)
            record.lastPlayed = existing.lastPlayed ?? track.lastPlayed
            record.dateAdded = existing.dateAdded
            record.favorite = existing.favorite || track.favorite
            record.notes = existing.notes.isEmpty ? track.notes : existing.notes
            if record.artworkKey == nil { record.artworkKey = existing.artworkKey }
            if record.musicBrainzRecordingID == nil { record.musicBrainzRecordingID = existing.musicBrainzRecordingID }
            if record.musicBrainzReleaseID == nil { record.musicBrainzReleaseID = existing.musicBrainzReleaseID }
            try record.update(db)
        } else {
            record.id = nil
            try record.insert(db)
        }
        return record
    }

    /// Removes tracks whose `libraryKey` starts with `prefix` but is not in `keep`.
    @discardableResult
    public static func removeMissing(_ db: Database, keyPrefix prefix: String, keep: Set<String>) throws -> Int {
        let keys = try String.fetchAll(db, sql: "SELECT libraryKey FROM tracks WHERE libraryKey LIKE ? ESCAPE '\\'",
                                       arguments: [likeEscape(prefix) + "%"])
        var removed = 0
        for key in keys where !keep.contains(key) {
            try db.execute(sql: "DELETE FROM tracks WHERE libraryKey = ?", arguments: [key])
            removed += 1
        }
        return removed
    }
}
