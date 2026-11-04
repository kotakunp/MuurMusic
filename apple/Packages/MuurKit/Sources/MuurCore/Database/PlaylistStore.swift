import Foundation
import GRDB

/// Supported playlist export formats.
public enum PlaylistExportFormat: String, CaseIterable, Sendable {
    case m3u8, m3u, pls, smart

    public var fileExtension: String {
        switch self {
        case .m3u8: return "m3u8"
        case .m3u: return "m3u"
        case .pls: return "pls"
        case .smart: return "muursmart.json"
        }
    }
}

/// Result of importing a playlist file.
public struct PlaylistImportResult: Sendable {
    public var playlist: Playlist
    public var matchedCount: Int
    /// Entries that could not be matched to a library track (kept as placeholders that relink on rescan).
    public var unmatched: [PlaylistEntry]
}

/// Synchronous playlist queries (usable inside value observations).
public enum PlaylistQueries {
    public static func playlists(_ db: Database) throws -> [Playlist] {
        try Playlist.fetchAll(db, sql: "SELECT * FROM playlists ORDER BY sortIndex, name COLLATE NOCASE")
    }

    public static func playlist(_ db: Database, id: Int64) throws -> Playlist? {
        try Playlist.fetchOne(db, sql: "SELECT * FROM playlists WHERE id = ?", arguments: [id])
    }

    public static func items(_ db: Database, playlistID: Int64) throws -> [PlaylistItem] {
        try PlaylistItem.fetchAll(db, sql: "SELECT * FROM playlist_items WHERE playlistId = ? ORDER BY position, id", arguments: [playlistID])
    }

    /// Playlist contents. Smart playlists are evaluated now; missing tracks become placeholder tracks.
    public static func contents(_ db: Database, id: Int64, now: Date = Date()) throws -> PlaylistWithTracks? {
        guard let record = try playlist(db, id: id) else { return nil }
        if record.isSmart, let definition = record.smartDefinition {
            let tracks = try SmartPlaylistCompiler.compile(definition, now: now).fetch(db)
            let items = tracks.enumerated().map { index, track in
                PlaylistItem(id: nil, playlistId: id, trackId: track.id, sourceURI: track.sourceURI, libraryKey: track.libraryKey,
                             title: track.displayTitle, artist: track.displayArtist, duration: track.duration, position: index)
            }
            return PlaylistWithTracks(playlist: record, items: items, tracks: tracks)
        }
        let storedItems = try items(db, playlistID: id)
        let ids = storedItems.compactMap(\.trackId)
        var byID: [Int64: Track] = [:]
        for track in try LibraryQueries.tracks(db, orderedIDs: ids) {
            if let trackID = track.id { byID[trackID] = track }
        }
        let tracks = storedItems.map { item -> Track in
            if let trackID = item.trackId, let track = byID[trackID] { return track }
            return Track(libraryKey: item.libraryKey, sourceURI: item.sourceURI, fileName: PathUtils.lastComponent(item.sourceURI),
                         title: item.title, artist: item.artist, duration: item.duration)
        }
        return PlaylistWithTracks(playlist: record, items: storedItems, tracks: tracks)
    }

    /// Number of tracks and total duration per playlist (smart playlists evaluated).
    public static func summary(_ db: Database, id: Int64) throws -> (count: Int, duration: Double) {
        guard let loaded = try contents(db, id: id) else { return (0, 0) }
        return (loaded.tracks.count, loaded.tracks.reduce(0) { $0 + $1.duration })
    }

    static func renumber(_ db: Database, playlistID: Int64, orderedItemIDs: [Int64]) throws {
        for (index, itemID) in orderedItemIDs.enumerated() {
            try db.execute(sql: "UPDATE playlist_items SET position = ? WHERE id = ?", arguments: [index, itemID])
        }
        try db.execute(sql: "UPDATE playlists SET updatedAt = ? WHERE id = ?", arguments: [Date().timeIntervalSince1970, playlistID])
    }
}

/// Playlist CRUD, ordering, smart playlists, import and export.
public final class PlaylistStore: Sendable {
    public let database: MuurDatabase

    public init(database: MuurDatabase) {
        self.database = database
    }

    // MARK: Reads

    public func playlists() async throws -> [Playlist] {
        try await database.read { db in try PlaylistQueries.playlists(db) }
    }

    public func observePlaylists() -> AsyncValueObservation<[Playlist]> {
        database.observe { db in try PlaylistQueries.playlists(db) }
    }

    public func contents(of id: Int64) async throws -> PlaylistWithTracks? {
        try await database.read { db in try PlaylistQueries.contents(db, id: id) }
    }

    public func observeContents(of id: Int64) -> AsyncValueObservation<PlaylistWithTracks?> {
        database.observe { db in try PlaylistQueries.contents(db, id: id) }
    }

    // MARK: Playlist CRUD

    @discardableResult
    public func create(name: String, tracks: [Track] = []) async throws -> Playlist {
        try await database.write { db in
            let nextIndex = (try Int.fetchOne(db, sql: "SELECT max(sortIndex) FROM playlists") ?? -1) + 1
            var playlist = Playlist(name: name, sortIndex: nextIndex)
            try playlist.insert(db)
            if let id = playlist.id {
                try PlaylistStore.insertItems(db, playlistID: id, tracks: tracks, at: nil)
            }
            return playlist
        }
    }

    @discardableResult
    public func createSmart(_ definition: SmartPlaylistDefinition) async throws -> Playlist {
        try await database.write { db in
            let nextIndex = (try Int.fetchOne(db, sql: "SELECT max(sortIndex) FROM playlists") ?? -1) + 1
            var playlist = Playlist(name: definition.name, isSmart: true, smartDefinition: definition, sortIndex: nextIndex)
            try playlist.insert(db)
            return playlist
        }
    }

    public func updateSmart(id: Int64, definition: SmartPlaylistDefinition) async throws {
        try await database.write { db in
            guard var playlist = try PlaylistQueries.playlist(db, id: id) else { throw MuurError.notFound("Playlist") }
            playlist.isSmart = true
            playlist.smartDefinition = definition
            playlist.name = definition.name
            playlist.updatedAt = Date()
            try playlist.update(db)
        }
    }

    public func rename(id: Int64, to name: String) async throws {
        try await database.write { db in
            try db.execute(sql: "UPDATE playlists SET name = ?, updatedAt = ? WHERE id = ?", arguments: [name, Date().timeIntervalSince1970, id])
            if let playlist = try PlaylistQueries.playlist(db, id: id), playlist.isSmart, var definition = playlist.smartDefinition {
                definition.name = name
                var updated = playlist
                updated.smartDefinition = definition
                try updated.update(db)
            }
        }
    }

    public func setNotes(id: Int64, notes: String) async throws {
        try await database.write { db in
            try db.execute(sql: "UPDATE playlists SET notes = ?, updatedAt = ? WHERE id = ?", arguments: [notes, Date().timeIntervalSince1970, id])
        }
    }

    public func setArtworkKey(id: Int64, artworkKey: String?) async throws {
        try await database.write { db in
            try db.execute(sql: "UPDATE playlists SET artworkKey = ? WHERE id = ?", arguments: [artworkKey, id])
        }
    }

    public func delete(id: Int64) async throws {
        try await database.write { db in try db.execute(sql: "DELETE FROM playlists WHERE id = ?", arguments: [id]) }
    }

    @discardableResult
    public func duplicate(id: Int64) async throws -> Playlist {
        try await database.write { db in
            guard let source = try PlaylistQueries.playlist(db, id: id) else { throw MuurError.notFound("Playlist") }
            var copy = source
            let newName = source.name + " Copy"
            copy.id = nil
            copy.name = newName
            copy.smartDefinition?.name = newName
            copy.createdAt = Date()
            copy.updatedAt = Date()
            try copy.insert(db)
            if let newID = copy.id, !source.isSmart {
                try db.execute(sql: """
                    INSERT INTO playlist_items(playlistId, trackId, sourceURI, libraryKey, title, artist, duration, position)
                    SELECT ?, trackId, sourceURI, libraryKey, title, artist, duration, position FROM playlist_items WHERE playlistId = ?
                    """, arguments: [newID, id])
            }
            return copy
        }
    }

    /// Reorders playlists in the sidebar.
    public func reorderPlaylists(_ orderedIDs: [Int64]) async throws {
        try await database.write { db in
            for (index, id) in orderedIDs.enumerated() {
                try db.execute(sql: "UPDATE playlists SET sortIndex = ? WHERE id = ?", arguments: [index, id])
            }
        }
    }

    // MARK: Items

    /// Adds tracks at `position` (nil = append).
    public func add(_ tracks: [Track], to playlistID: Int64, at position: Int? = nil) async throws {
        guard !tracks.isEmpty else { return }
        try await database.write { db in
            try PlaylistStore.insertItems(db, playlistID: playlistID, tracks: tracks, at: position)
        }
    }

    public func remove(itemIDs: [Int64], from playlistID: Int64) async throws {
        guard !itemIDs.isEmpty else { return }
        try await database.write { db in
            for itemID in itemIDs {
                try db.execute(sql: "DELETE FROM playlist_items WHERE id = ? AND playlistId = ?", arguments: [itemID, playlistID])
            }
            let remaining = try Int64.fetchAll(db, sql: "SELECT id FROM playlist_items WHERE playlistId = ? ORDER BY position, id", arguments: [playlistID])
            try PlaylistQueries.renumber(db, playlistID: playlistID, orderedItemIDs: remaining)
        }
    }

    /// Removes items at the given offsets (SwiftUI `onDelete`).
    public func remove(atOffsets offsets: IndexSet, from playlistID: Int64) async throws {
        try await database.write { db in
            let ids = try Int64.fetchAll(db, sql: "SELECT id FROM playlist_items WHERE playlistId = ? ORDER BY position, id", arguments: [playlistID])
            let remaining = ids.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
            for (offset, itemID) in ids.enumerated() where offsets.contains(offset) {
                try db.execute(sql: "DELETE FROM playlist_items WHERE id = ?", arguments: [itemID])
            }
            try PlaylistQueries.renumber(db, playlistID: playlistID, orderedItemIDs: remaining)
        }
    }

    /// Moves items like SwiftUI's `onMove(fromOffsets:toOffset:)`.
    public func move(in playlistID: Int64, fromOffsets source: IndexSet, toOffset destination: Int) async throws {
        try await database.write { db in
            let ids = try Int64.fetchAll(db, sql: "SELECT id FROM playlist_items WHERE playlistId = ? ORDER BY position, id", arguments: [playlistID])
            let reordered = PlaylistStore.moved(ids, fromOffsets: source, toOffset: destination)
            try PlaylistQueries.renumber(db, playlistID: playlistID, orderedItemIDs: reordered)
        }
    }

    public func clear(_ playlistID: Int64) async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM playlist_items WHERE playlistId = ?", arguments: [playlistID])
        }
    }

    /// Array reordering with SwiftUI `move(fromOffsets:toOffset:)` semantics.
    public static func moved<Element>(_ array: [Element], fromOffsets source: IndexSet, toOffset destination: Int) -> [Element] {
        let moving = source.filter { array.indices.contains($0) }.map { array[$0] }
        var result: [Element] = []
        var inserted = false
        for (index, element) in array.enumerated() {
            if index == destination {
                result.append(contentsOf: moving)
                inserted = true
            }
            if !source.contains(index) { result.append(element) }
        }
        if !inserted { result.append(contentsOf: moving) }
        return result
    }

    static func insertItems(_ db: Database, playlistID: Int64, tracks: [Track], at position: Int?) throws {
        let existing = try Int64.fetchAll(db, sql: "SELECT id FROM playlist_items WHERE playlistId = ? ORDER BY position, id", arguments: [playlistID])
        let insertAt = min(max(position ?? existing.count, 0), existing.count)
        var newIDs: [Int64] = []
        for track in tracks {
            var item = PlaylistItem(playlistId: playlistID, trackId: track.id, sourceURI: track.sourceURI, libraryKey: track.libraryKey,
                                    title: track.displayTitle, artist: track.displayArtist, duration: track.duration, position: 0)
            try item.insert(db)
            if let id = item.id { newIDs.append(id) }
        }
        var ordered = existing
        ordered.insert(contentsOf: newIDs, at: insertAt)
        try PlaylistQueries.renumber(db, playlistID: playlistID, orderedItemIDs: ordered)
    }

    // MARK: Import / export

    /// Imports a playlist file. `fileURI` is the playlist's own source URI (used for relative paths).
    @discardableResult
    public func importPlaylist(data: Data, fileName: String, fileURI: String?) async throws -> PlaylistImportResult {
        let lower = fileName.lowercased()
        if lower.hasSuffix(".muursmart.json") || lower.hasSuffix(".json") {
            let definition = try JSONDecoder().decode(SmartPlaylistDefinition.self, from: data)
            guard definition.format == "muur-smart" else { throw MuurError.invalidData("Not a muur-smart file") }
            let playlist = try await createSmart(definition)
            return PlaylistImportResult(playlist: playlist, matchedCount: 0, unmatched: [])
        }
        let entries: [PlaylistEntry]
        switch PathUtils.fileExtension(fileName) {
        case "m3u", "m3u8":
            entries = M3UPlaylist.parse(data: data, baseURI: fileURI)
        case "pls":
            entries = PLSPlaylist.parse(TextDecoding.decode(data), baseURI: fileURI)
        case "cue":
            let sheet = CueSheet.parse(data: data)
            entries = sheet.tracks.map { track in
                let audioURI = PlaylistPathResolver.resolve(track.fileName, baseURI: fileURI)
                return PlaylistEntry(location: track.fileName, resolvedURI: audioURI.map { "\($0)#cue=\(track.number)" },
                                     title: track.title, artist: track.performer.isEmpty ? sheet.performer : track.performer)
            }
        default:
            throw MuurError.unsupported("Playlist format .\(PathUtils.fileExtension(fileName))")
        }
        let name = PathUtils.titleFromFileName(fileName.replacingOccurrences(of: ".muursmart.json", with: ""))
        return try await database.write { db in
            var matched = 0
            var unmatched: [PlaylistEntry] = []
            var tracks: [Track] = []
            for entry in entries {
                if let track = try PlaylistStore.match(db, entry: entry) {
                    tracks.append(track)
                    matched += 1
                } else {
                    unmatched.append(entry)
                    let uri = entry.resolvedURI ?? entry.location
                    tracks.append(Track(libraryKey: uri, sourceURI: uri, fileName: entry.fileName,
                                        title: entry.title ?? PathUtils.titleFromFileName(entry.fileName),
                                        artist: entry.artist ?? "", duration: entry.duration ?? 0))
                }
            }
            let nextIndex = (try Int.fetchOne(db, sql: "SELECT max(sortIndex) FROM playlists") ?? -1) + 1
            var playlist = Playlist(name: name.isEmpty ? "Imported Playlist" : name, sortIndex: nextIndex)
            try playlist.insert(db)
            if let id = playlist.id {
                try PlaylistStore.insertItems(db, playlistID: id, tracks: tracks, at: nil)
            }
            return PlaylistImportResult(playlist: playlist, matchedCount: matched, unmatched: unmatched)
        }
    }

    /// Finds the library track for a playlist entry: by URI, then by file name (and duration when known).
    static func match(_ db: Database, entry: PlaylistEntry) throws -> Track? {
        if let uri = entry.resolvedURI {
            if let track = try LibraryQueries.track(db, libraryKey: uri) { return track }
            if let track = try LibraryQueries.tracks(db, sourceURI: uri).first { return track }
        }
        let fileName = entry.fileName
        guard !fileName.isEmpty else { return nil }
        let candidates = try Track.fetchAll(db, sql: "SELECT * FROM tracks WHERE fileName = ? COLLATE NOCASE AND cueStart IS NULL",
                                            arguments: [fileName])
        if let duration = entry.duration, duration > 0 {
            return candidates.first { abs($0.duration - duration) < 3 } ?? candidates.first
        }
        return candidates.first
    }

    /// Serializes a playlist. `fileURI` is where the file will be written (for relative paths).
    public func export(id: Int64, format: PlaylistExportFormat, fileURI: String?) async throws -> Data {
        guard let loaded = try await contents(of: id) else { throw MuurError.notFound("Playlist") }
        switch format {
        case .smart:
            let definition = loaded.playlist.smartDefinition ?? SmartPlaylistDefinition(name: loaded.playlist.name)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(definition)
        case .m3u8, .m3u:
            let items = loaded.tracks.map { PlaylistWriteItem(track: $0) }
            return Data(M3UPlaylist.write(items, playlistURI: fileURI).utf8)
        case .pls:
            let items = loaded.tracks.map { PlaylistWriteItem(track: $0) }
            return Data(PLSPlaylist.write(items, playlistURI: fileURI).utf8)
        }
    }
}
