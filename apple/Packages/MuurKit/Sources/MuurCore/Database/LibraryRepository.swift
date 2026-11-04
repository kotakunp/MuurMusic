import Foundation
import GRDB

/// Async, `Sendable` facade over the library tables. Every method can be called from any actor.
/// `observe…` methods return GRDB `AsyncValueObservation` sequences that emit a fresh value whenever
/// the underlying tables change (use with `for try await` in a SwiftUI `.task`), or wrap a fetch in
/// `ObservedQuery` for an `ObservableObject`.
public final class LibraryRepository: Sendable {
    public let database: MuurDatabase

    public init(database: MuurDatabase) {
        self.database = database
    }

    // MARK: Reads

    public func tracks(filter: TrackFilter = .all, sort: TrackSort = TrackSort(), limit: Int? = nil) async throws -> [Track] {
        try await database.read { db in try LibraryQueries.tracks(db, filter: filter, sort: sort, limit: limit) }
    }

    public func trackCount(filter: TrackFilter = .all) async throws -> Int {
        try await database.read { db in try LibraryQueries.trackCount(db, filter: filter) }
    }

    public func track(id: Int64) async throws -> Track? {
        try await database.read { db in try LibraryQueries.track(db, id: id) }
    }

    public func track(libraryKey: String) async throws -> Track? {
        try await database.read { db in try LibraryQueries.track(db, libraryKey: libraryKey) }
    }

    public func tracks(sourceURI: String) async throws -> [Track] {
        try await database.read { db in try LibraryQueries.tracks(db, sourceURI: sourceURI) }
    }

    public func tracks(orderedIDs: [Int64]) async throws -> [Track] {
        try await database.read { db in try LibraryQueries.tracks(db, orderedIDs: orderedIDs) }
    }

    public func albums(filter: AlbumFilter = .all, sort: AlbumSort = .title, limit: Int? = nil) async throws -> [Album] {
        try await database.read { db in try LibraryQueries.albums(db, filter: filter, sort: sort, limit: limit) }
    }

    public func tracks(album: Album) async throws -> [Track] {
        try await database.read { db in try LibraryQueries.tracks(db, album: album) }
    }

    public func groups(kind: LibraryGroup.Kind, search: String? = nil) async throws -> [LibraryGroup] {
        try await database.read { db in try LibraryQueries.groups(db, kind: kind, search: search) }
    }

    public func folders(parent: String = "") async throws -> [LibraryFolder] {
        try await database.read { db in try LibraryQueries.folders(db, parent: parent) }
    }

    public func search(_ text: String, limit: Int = 100) async throws -> LibrarySearchResults {
        try await database.read { db in try LibraryQueries.search(db, text, limit: limit) }
    }

    public func stats() async throws -> LibraryStats {
        try await database.read { db in try LibraryQueries.stats(db) }
    }

    public func recentlyAdded(limit: Int = 50) async throws -> [Track] {
        try await database.read { db in try LibraryQueries.recentlyAdded(db, limit: limit) }
    }

    public func recentlyPlayed(limit: Int = 50) async throws -> [Track] {
        try await database.read { db in try LibraryQueries.recentlyPlayed(db, limit: limit) }
    }

    public func mostPlayed(limit: Int = 50) async throws -> [Track] {
        try await database.read { db in try LibraryQueries.mostPlayed(db, limit: limit) }
    }

    public func randomTracks(limit: Int = 100, filter: TrackFilter = .all) async throws -> [Track] {
        try await database.read { db in try LibraryQueries.randomTracks(db, limit: limit, filter: filter) }
    }

    public func history(limit: Int = 200) async throws -> [PlayHistoryEntry] {
        try await database.read { db in try LibraryQueries.history(db, limit: limit) }
    }

    public func bookmarks(libraryKey: String? = nil) async throws -> [Bookmark] {
        try await database.read { db in try LibraryQueries.bookmarks(db, libraryKey: libraryKey) }
    }

    // MARK: Observation

    public func observeTracks(filter: TrackFilter = .all, sort: TrackSort = TrackSort(), limit: Int? = nil) -> AsyncValueObservation<[Track]> {
        database.observe { db in try LibraryQueries.tracks(db, filter: filter, sort: sort, limit: limit) }
    }

    public func observeAlbums(filter: AlbumFilter = .all, sort: AlbumSort = .title) -> AsyncValueObservation<[Album]> {
        database.observe { db in try LibraryQueries.albums(db, filter: filter, sort: sort) }
    }

    public func observeGroups(kind: LibraryGroup.Kind) -> AsyncValueObservation<[LibraryGroup]> {
        database.observe { db in try LibraryQueries.groups(db, kind: kind) }
    }

    public func observeFolders(parent: String = "") -> AsyncValueObservation<[LibraryFolder]> {
        database.observe { db in try LibraryQueries.folders(db, parent: parent) }
    }

    public func observeStats() -> AsyncValueObservation<LibraryStats> {
        database.observe { db in try LibraryQueries.stats(db) }
    }

    public func observeHistory(limit: Int = 200) -> AsyncValueObservation<[PlayHistoryEntry]> {
        database.observe { db in try LibraryQueries.history(db, limit: limit) }
    }

    public func observeRecentlyPlayed(limit: Int = 50) -> AsyncValueObservation<[Track]> {
        database.observe { db in try LibraryQueries.recentlyPlayed(db, limit: limit) }
    }

    public func observeTrack(id: Int64) -> AsyncValueObservation<Track?> {
        database.observe { db in try LibraryQueries.track(db, id: id) }
    }

    public func observeBookmarks(libraryKey: String? = nil) -> AsyncValueObservation<[Bookmark]> {
        database.observe { db in try LibraryQueries.bookmarks(db, libraryKey: libraryKey) }
    }

    public func observeSources() -> AsyncValueObservation<[SourceConfig]> {
        database.observe { db in try LibraryQueries.sources(db) }
    }

    // MARK: Track mutations

    /// Inserts or updates tracks (keyed by `libraryKey`), preserving user data. Returns the stored rows.
    @discardableResult
    public func upsert(_ tracks: [Track]) async throws -> [Track] {
        guard !tracks.isEmpty else { return [] }
        return try await database.write { db in try tracks.map { try LibraryQueries.upsert(db, $0) } }
    }

    /// Saves all fields of an existing track (tag edits, metadata lookups).
    public func update(_ track: Track) async throws {
        try await database.write { db in
            if track.id != nil {
                try track.update(db)
            } else {
                try LibraryQueries.upsert(db, track)
            }
        }
    }

    public func delete(trackIDs: [Int64]) async throws {
        guard !trackIDs.isEmpty else { return }
        try await database.write { db in
            let (clause, args) = TrackFilter.ids(trackIDs).clause()
            try db.execute(sql: "DELETE FROM tracks WHERE \(clause)", arguments: StatementArguments(args))
        }
    }

    /// Removes every track belonging to a configured source.
    public func deleteTracks(sourceID: UUID) async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM tracks WHERE sourceID = ?", arguments: [sourceID.uuidString])
        }
    }

    /// Removes tracks whose source URI starts with `prefix` (e.g. a removed watched folder).
    public func deleteTracks(uriPrefix prefix: String) async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM tracks WHERE sourceURI LIKE ? ESCAPE '\\'", arguments: [LibraryQueries.likeEscape(prefix) + "%"])
        }
    }

    public func setRating(_ rating: Int, trackID: Int64) async throws {
        let value = min(max(rating, 0), 5)
        try await database.write { db in
            try db.execute(sql: "UPDATE tracks SET rating = ? WHERE id = ?", arguments: [value, trackID])
        }
    }

    public func setFavorite(_ favorite: Bool, trackID: Int64) async throws {
        try await database.write { db in
            try db.execute(sql: "UPDATE tracks SET favorite = ? WHERE id = ?", arguments: [favorite, trackID])
        }
    }

    /// Toggles the favorite flag and returns the new value.
    @discardableResult
    public func toggleFavorite(trackID: Int64) async throws -> Bool {
        try await database.write { db in
            try db.execute(sql: "UPDATE tracks SET favorite = 1 - favorite WHERE id = ?", arguments: [trackID])
            return try Bool.fetchOne(db, sql: "SELECT favorite FROM tracks WHERE id = ?", arguments: [trackID]) ?? false
        }
    }

    public func setNotes(_ notes: String, trackID: Int64) async throws {
        try await database.write { db in
            try db.execute(sql: "UPDATE tracks SET notes = ? WHERE id = ?", arguments: [notes, trackID])
        }
    }

    public func setArtworkKey(_ key: String?, trackIDs: [Int64]) async throws {
        guard !trackIDs.isEmpty else { return }
        try await database.write { db in
            let (clause, args) = TrackFilter.ids(trackIDs).clause()
            try db.execute(sql: "UPDATE tracks SET artworkKey = ? WHERE \(clause)", arguments: StatementArguments([key as (any DatabaseValueConvertible)?] + args))
        }
    }

    public func setLyrics(_ lyrics: String?, trackID: Int64) async throws {
        try await database.write { db in
            let has = !(lyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            try db.execute(sql: "UPDATE tracks SET lyrics = ?, hasLyrics = ? WHERE id = ?", arguments: [lyrics, has, trackID])
        }
    }

    /// Records a finished (or sufficiently long) play: history entry, play count and last played date.
    public func recordPlay(of track: Track, listenedSeconds: Double, at date: Date = Date()) async throws {
        try await database.write { db in
            var trackID = track.id
            if trackID == nil {
                trackID = try Int64.fetchOne(db, sql: "SELECT id FROM tracks WHERE libraryKey = ?", arguments: [track.libraryKey])
            }
            if let trackID {
                try db.execute(sql: "UPDATE tracks SET playCount = playCount + 1, lastPlayed = ? WHERE id = ?",
                               arguments: [date.timeIntervalSince1970, trackID])
            }
            var entry = PlayHistoryEntry(trackId: trackID, sourceURI: track.sourceURI, libraryKey: track.libraryKey,
                                         title: track.displayTitle, artist: track.displayArtist, album: track.album,
                                         playedAt: date, listenedSeconds: listenedSeconds)
            try entry.insert(db)
        }
    }

    public func recordSkip(trackID: Int64) async throws {
        try await database.write { db in
            try db.execute(sql: "UPDATE tracks SET skipCount = skipCount + 1 WHERE id = ?", arguments: [trackID])
        }
    }

    public func clearHistory() async throws {
        try await database.write { db in try db.execute(sql: "DELETE FROM play_history") }
    }

    public func resetPlayCounts() async throws {
        try await database.write { db in
            try db.execute(sql: "UPDATE tracks SET playCount = 0, skipCount = 0, lastPlayed = NULL")
        }
    }

    // MARK: Bookmarks

    @discardableResult
    public func addBookmark(track: Track, position: Double, note: String = "") async throws -> Bookmark {
        try await database.write { db in
            var bookmark = Bookmark(trackId: track.id, sourceURI: track.sourceURI, libraryKey: track.libraryKey,
                                    title: track.displayTitle, artist: track.displayArtist, position: position, note: note)
            try bookmark.insert(db)
            return bookmark
        }
    }

    public func updateBookmark(_ bookmark: Bookmark) async throws {
        try await database.write { db in try bookmark.update(db) }
    }

    public func deleteBookmark(id: Int64) async throws {
        try await database.write { db in try db.execute(sql: "DELETE FROM bookmarks WHERE id = ?", arguments: [id]) }
    }

    // MARK: Sources

    public func sources() async throws -> [SourceConfig] {
        try await database.read { db in try LibraryQueries.sources(db) }
    }

    public func source(id: UUID) async throws -> SourceConfig? {
        try await database.read { db in
            try SourceConfig.fetchOne(db, sql: "SELECT * FROM sources WHERE id = ?", arguments: [id.uuidString.uppercased()])
        }
    }

    public func save(source: SourceConfig) async throws {
        try await database.write { db in try source.save(db) }
    }

    /// Deletes a source configuration and its tracks (credentials are removed by `SourceManager`).
    public func deleteSource(id: UUID) async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM sources WHERE id = ?", arguments: [id.uuidString.uppercased()])
            try db.execute(sql: "DELETE FROM tracks WHERE sourceID = ?", arguments: [id.uuidString])
        }
    }

    // MARK: Watched folders

    public func watchedFolders() async throws -> [WatchedFolder] {
        try await database.read { db in try LibraryQueries.watchedFolders(db) }
    }

    public func observeWatchedFolders() -> AsyncValueObservation<[WatchedFolder]> {
        database.observe { db in try LibraryQueries.watchedFolders(db) }
    }

    public func save(watchedFolder: WatchedFolder) async throws {
        try await database.write { db in try watchedFolder.save(db) }
    }

    public func deleteWatchedFolder(id: String) async throws {
        try await database.write { db in try db.execute(sql: "DELETE FROM watched_folders WHERE id = ?", arguments: [id]) }
    }
}
