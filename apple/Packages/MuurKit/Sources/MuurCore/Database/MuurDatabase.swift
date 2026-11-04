import Foundation
import GRDB

/// The library database (`library.sqlite`). Wraps a GRDB `DatabasePool` (WAL mode, concurrent reads)
/// and applies forward-only migrations tracked in `PRAGMA user_version`.
///
/// Thread safety: `MuurDatabase` is `Sendable`. Use the async `read`/`write` helpers from any context;
/// synchronous access through `writer` must not happen on the main thread for long operations.
public final class MuurDatabase: Sendable {
    /// The underlying GRDB writer (a `DatabasePool` on disk, a `DatabaseQueue` in memory).
    public let writer: any DatabaseWriter

    public var reader: any DatabaseReader { writer }

    /// Opens (creating if needed) the database at `url` and migrates it.
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.label = "MuurLibrary"
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        self.writer = pool
        try MuurSchema.migrate(pool)
    }

    private init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try MuurSchema.migrate(writer)
    }

    /// A migrated in-memory database (tests, previews).
    public static func inMemory() throws -> MuurDatabase {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        return try MuurDatabase(writer: DatabaseQueue(configuration: configuration))
    }

    /// Current schema version (`PRAGMA user_version`).
    public var schemaVersion: Int {
        (try? writer.read { db in try Int.fetchOne(db, sql: "PRAGMA user_version") }) ?? 0
    }

    // MARK: Access helpers

    public func read<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await writer.read(body)
    }

    public func write<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await writer.write(body)
    }

    /// An async sequence of values re-fetched whenever the tables read by `fetch` change.
    public func observe<T: Sendable>(_ fetch: @escaping @Sendable (Database) throws -> T) -> AsyncValueObservation<T> {
        ValueObservation.tracking(fetch).values(in: writer)
    }

    // MARK: Settings table

    /// Reads a value from the `settings` key/value table.
    public func setting(_ key: String) -> String? {
        try? writer.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key])
        }
    }

    /// Writes (or removes, when `value` is nil) a value in the `settings` table.
    public func setSetting(_ key: String, _ value: String?) {
        do {
            try writer.write { db in
                if let value {
                    try db.execute(sql: "INSERT INTO settings(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                                   arguments: [key, value])
                } else {
                    try db.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [key])
                }
            }
        } catch {
            Log.database.error("Failed to write setting \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Runs `VACUUM` and FTS optimisation (call occasionally, e.g. after large deletions).
    public func optimize() async throws {
        try await writer.barrierWriteWithoutTransaction { db in
            try db.execute(sql: "INSERT INTO tracks_fts(tracks_fts) VALUES('optimize')")
            try db.execute(sql: "VACUUM")
        }
    }
}

/// Schema definition and migrations. Versions are stored in `PRAGMA user_version`; migrations only move forward.
enum MuurSchema {
    static var latestVersion: Int { migrations().count }

    static func migrations() -> [(Database) throws -> Void] {
        [migrateV1]
    }

    static func migrate(_ writer: any DatabaseWriter) throws {
        try writer.barrierWriteWithoutTransaction { db in
            let current = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            let all = migrations()
            guard current < all.count else { return }
            for index in current..<all.count {
                try db.inTransaction {
                    try all[index](db)
                    try db.execute(sql: "PRAGMA user_version = \(index + 1)")
                    return .commit
                }
                Log.database.info("Migrated library database to version \(index + 1)")
            }
        }
    }

    static let ftsColumns = ["title", "artist", "album", "albumArtist", "genre", "composer", "fileName"]

    private static func migrateV1(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE tracks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                libraryKey TEXT NOT NULL UNIQUE,
                sourceURI TEXT NOT NULL,
                sourceID TEXT,
                folderPath TEXT NOT NULL DEFAULT '',
                fileName TEXT NOT NULL DEFAULT '',
                title TEXT NOT NULL DEFAULT '',
                artist TEXT NOT NULL DEFAULT '',
                album TEXT NOT NULL DEFAULT '',
                albumArtist TEXT NOT NULL DEFAULT '',
                genre TEXT NOT NULL DEFAULT '',
                composer TEXT NOT NULL DEFAULT '',
                year INTEGER,
                trackNumber INTEGER,
                trackTotal INTEGER,
                discNumber INTEGER,
                discTotal INTEGER,
                bpm INTEGER,
                comment TEXT NOT NULL DEFAULT '',
                lyrics TEXT,
                hasLyrics INTEGER NOT NULL DEFAULT 0,
                notes TEXT NOT NULL DEFAULT '',
                rating INTEGER NOT NULL DEFAULT 0,
                playCount INTEGER NOT NULL DEFAULT 0,
                skipCount INTEGER NOT NULL DEFAULT 0,
                lastPlayed REAL,
                dateAdded REAL NOT NULL,
                fileModified REAL,
                favorite INTEGER NOT NULL DEFAULT 0,
                duration REAL NOT NULL DEFAULT 0,
                bitrate INTEGER NOT NULL DEFAULT 0,
                sampleRate REAL NOT NULL DEFAULT 0,
                bitDepth INTEGER NOT NULL DEFAULT 0,
                channels INTEGER NOT NULL DEFAULT 0,
                codec TEXT NOT NULL DEFAULT '',
                fileSize INTEGER NOT NULL DEFAULT 0,
                cueStart REAL,
                cueEnd REAL,
                cueSheetURI TEXT,
                artworkKey TEXT,
                replayGainTrackGain REAL,
                replayGainTrackPeak REAL,
                replayGainAlbumGain REAL,
                replayGainAlbumPeak REAL,
                musicBrainzRecordingID TEXT,
                musicBrainzReleaseID TEXT
            )
            """)
        for column in ["sourceURI", "sourceID", "folderPath", "album COLLATE NOCASE", "artist COLLATE NOCASE",
                       "albumArtist COLLATE NOCASE", "genre COLLATE NOCASE", "composer COLLATE NOCASE", "dateAdded",
                       "lastPlayed", "playCount", "favorite", "title COLLATE NOCASE"] {
            let name = column.components(separatedBy: " ")[0]
            try db.execute(sql: "CREATE INDEX tracks_\(name) ON tracks(\(column))")
        }

        let cols = ftsColumns.joined(separator: ", ")
        let newCols = ftsColumns.map { "new.\($0)" }.joined(separator: ", ")
        let oldCols = ftsColumns.map { "old.\($0)" }.joined(separator: ", ")
        try db.execute(sql: """
            CREATE VIRTUAL TABLE tracks_fts USING fts5(\(cols), content='tracks', content_rowid='id',
                tokenize='unicode61 remove_diacritics 2', prefix='2 3')
            """)
        try db.execute(sql: """
            CREATE TRIGGER tracks_fts_ai AFTER INSERT ON tracks BEGIN
                INSERT INTO tracks_fts(rowid, \(cols)) VALUES (new.id, \(newCols));
            END
            """)
        try db.execute(sql: """
            CREATE TRIGGER tracks_fts_ad AFTER DELETE ON tracks BEGIN
                INSERT INTO tracks_fts(tracks_fts, rowid, \(cols)) VALUES ('delete', old.id, \(oldCols));
            END
            """)
        try db.execute(sql: """
            CREATE TRIGGER tracks_fts_au AFTER UPDATE OF \(cols) ON tracks BEGIN
                INSERT INTO tracks_fts(tracks_fts, rowid, \(cols)) VALUES ('delete', old.id, \(oldCols));
                INSERT INTO tracks_fts(rowid, \(cols)) VALUES (new.id, \(newCols));
            END
            """)

        try db.execute(sql: """
            CREATE TABLE playlists (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                isSmart INTEGER NOT NULL DEFAULT 0,
                smartDefinition TEXT,
                notes TEXT NOT NULL DEFAULT '',
                artworkKey TEXT,
                sortIndex INTEGER NOT NULL DEFAULT 0,
                createdAt REAL NOT NULL,
                updatedAt REAL NOT NULL
            );
            CREATE TABLE playlist_items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                playlistId INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
                trackId INTEGER REFERENCES tracks(id) ON DELETE SET NULL,
                sourceURI TEXT NOT NULL,
                libraryKey TEXT NOT NULL,
                title TEXT NOT NULL DEFAULT '',
                artist TEXT NOT NULL DEFAULT '',
                duration REAL NOT NULL DEFAULT 0,
                position INTEGER NOT NULL
            );
            CREATE INDEX playlist_items_playlist ON playlist_items(playlistId, position);
            CREATE INDEX playlist_items_track ON playlist_items(trackId);
            CREATE INDEX playlist_items_key ON playlist_items(libraryKey);

            CREATE TABLE sources (
                id TEXT PRIMARY KEY NOT NULL,
                kind TEXT NOT NULL,
                name TEXT NOT NULL,
                host TEXT NOT NULL DEFAULT '',
                port INTEGER,
                basePath TEXT NOT NULL DEFAULT '',
                username TEXT NOT NULL DEFAULT '',
                options TEXT NOT NULL DEFAULT '{}',
                sortIndex INTEGER NOT NULL DEFAULT 0,
                createdAt REAL NOT NULL
            );

            CREATE TABLE bookmarks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                trackId INTEGER REFERENCES tracks(id) ON DELETE SET NULL,
                sourceURI TEXT NOT NULL,
                libraryKey TEXT NOT NULL,
                title TEXT NOT NULL DEFAULT '',
                artist TEXT NOT NULL DEFAULT '',
                position REAL NOT NULL,
                note TEXT NOT NULL DEFAULT '',
                createdAt REAL NOT NULL
            );
            CREATE INDEX bookmarks_key ON bookmarks(libraryKey);

            CREATE TABLE play_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                trackId INTEGER REFERENCES tracks(id) ON DELETE SET NULL,
                sourceURI TEXT NOT NULL,
                libraryKey TEXT NOT NULL,
                title TEXT NOT NULL DEFAULT '',
                artist TEXT NOT NULL DEFAULT '',
                album TEXT NOT NULL DEFAULT '',
                playedAt REAL NOT NULL,
                listenedSeconds REAL NOT NULL DEFAULT 0
            );
            CREATE INDEX play_history_playedAt ON play_history(playedAt);

            CREATE TABLE watched_folders (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                path TEXT NOT NULL,
                bookmark BLOB,
                isAppDocuments INTEGER NOT NULL DEFAULT 0,
                enabled INTEGER NOT NULL DEFAULT 1,
                lastScan REAL
            );

            CREATE TABLE downloads (
                id TEXT PRIMARY KEY NOT NULL,
                sourceURI TEXT NOT NULL UNIQUE,
                sourceID TEXT,
                title TEXT NOT NULL DEFAULT '',
                artist TEXT NOT NULL DEFAULT '',
                album TEXT NOT NULL DEFAULT '',
                state TEXT NOT NULL,
                progress REAL NOT NULL DEFAULT 0,
                bytesReceived INTEGER NOT NULL DEFAULT 0,
                bytesExpected INTEGER NOT NULL DEFAULT 0,
                localPath TEXT,
                errorMessage TEXT,
                groupName TEXT,
                trackId INTEGER,
                retryCount INTEGER NOT NULL DEFAULT 0,
                createdAt REAL NOT NULL,
                updatedAt REAL NOT NULL
            );
            CREATE INDEX downloads_state ON downloads(state);

            CREATE TABLE eq_presets (
                name TEXT PRIMARY KEY NOT NULL,
                preampDb REAL NOT NULL DEFAULT 0,
                bandsJSON TEXT NOT NULL,
                sortIndex INTEGER NOT NULL DEFAULT 0
            );

            CREATE TABLE dsp_chains (
                name TEXT PRIMARY KEY NOT NULL,
                json TEXT NOT NULL,
                updatedAt REAL NOT NULL
            );

            CREATE TABLE settings (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT
            );

            CREATE TRIGGER tracks_relink AFTER INSERT ON tracks BEGIN
                UPDATE playlist_items SET trackId = new.id WHERE trackId IS NULL AND libraryKey = new.libraryKey;
                UPDATE bookmarks SET trackId = new.id WHERE trackId IS NULL AND libraryKey = new.libraryKey;
                UPDATE play_history SET trackId = new.id WHERE trackId IS NULL AND libraryKey = new.libraryKey;
            END;

            CREATE VIEW albums AS
                SELECT lower(min(album)) || char(31) || lower(min(CASE WHEN albumArtist <> '' THEN albumArtist ELSE artist END)) AS id,
                       min(album) AS title,
                       min(CASE WHEN albumArtist <> '' THEN albumArtist ELSE artist END) AS artist,
                       max(year) AS year,
                       max(genre) AS genre,
                       count(*) AS trackCount,
                       sum(duration) AS duration,
                       max(artworkKey) AS artworkKey,
                       max(sampleRate) AS maxSampleRate,
                       max(bitDepth) AS maxBitDepth,
                       max(codec) AS codec,
                       min(dateAdded) AS dateAdded,
                       sum(playCount) AS playCount
                FROM tracks
                GROUP BY album COLLATE NOCASE, (CASE WHEN albumArtist <> '' THEN albumArtist ELSE artist END) COLLATE NOCASE;
            """)
    }
}
