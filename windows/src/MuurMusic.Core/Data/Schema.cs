namespace MuurMusic.Core.Data;

/// <summary>Forward-only schema migrations. Index N migrates from user_version N to N+1.</summary>
internal static class Schema
{
    public static readonly IReadOnlyList<string> Migrations = new[]
    {
        """
        CREATE TABLE sources (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            name TEXT NOT NULL,
            config_json TEXT NOT NULL DEFAULT '{}',
            enabled INTEGER NOT NULL DEFAULT 1,
            sort_order INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL
        );

        CREATE TABLE tracks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            source_uri TEXT NOT NULL,
            source_id TEXT NULL,
            file_path TEXT NULL,
            folder TEXT NULL,
            file_name TEXT NOT NULL DEFAULT '',
            cue_start_ms INTEGER NOT NULL DEFAULT 0,
            cue_end_ms INTEGER NULL,
            cue_sheet_path TEXT NULL,
            title TEXT NULL,
            artist TEXT NULL,
            album TEXT NULL,
            album_artist TEXT NULL,
            album_key TEXT NOT NULL DEFAULT '',
            genre TEXT NULL,
            composer TEXT NULL,
            year INTEGER NULL,
            track_number INTEGER NULL,
            track_total INTEGER NULL,
            disc_number INTEGER NULL,
            disc_total INTEGER NULL,
            bpm INTEGER NULL,
            comment TEXT NULL,
            has_lyrics INTEGER NOT NULL DEFAULT 0,
            rating INTEGER NOT NULL DEFAULT 0,
            play_count INTEGER NOT NULL DEFAULT 0,
            skip_count INTEGER NOT NULL DEFAULT 0,
            last_played INTEGER NULL,
            date_added INTEGER NOT NULL,
            favorite INTEGER NOT NULL DEFAULT 0,
            duration_ms INTEGER NOT NULL DEFAULT 0,
            bitrate INTEGER NOT NULL DEFAULT 0,
            sample_rate INTEGER NOT NULL DEFAULT 0,
            bit_depth INTEGER NOT NULL DEFAULT 0,
            channels INTEGER NOT NULL DEFAULT 0,
            codec TEXT NULL,
            format TEXT NULL,
            file_size INTEGER NOT NULL DEFAULT 0,
            file_mtime INTEGER NOT NULL DEFAULT 0,
            artwork_hash TEXT NULL,
            rg_track_gain REAL NULL,
            rg_track_peak REAL NULL,
            rg_album_gain REAL NULL,
            rg_album_peak REAL NULL,
            is_remote INTEGER NOT NULL DEFAULT 0,
            local_copy_path TEXT NULL,
            mb_recording_id TEXT NULL,
            mb_release_id TEXT NULL,
            unavailable INTEGER NOT NULL DEFAULT 0,
            artwork_url TEXT NULL,
            UNIQUE (source_uri, cue_start_ms)
        );
        CREATE INDEX ix_tracks_album ON tracks(album_key, disc_number, track_number);
        CREATE INDEX ix_tracks_artist ON tracks(artist COLLATE NOCASE);
        CREATE INDEX ix_tracks_album_artist ON tracks(album_artist COLLATE NOCASE);
        CREATE INDEX ix_tracks_genre ON tracks(genre COLLATE NOCASE);
        CREATE INDEX ix_tracks_composer ON tracks(composer COLLATE NOCASE);
        CREATE INDEX ix_tracks_folder ON tracks(folder);
        CREATE INDEX ix_tracks_file_path ON tracks(file_path);
        CREATE INDEX ix_tracks_date_added ON tracks(date_added);
        CREATE INDEX ix_tracks_last_played ON tracks(last_played);
        CREATE INDEX ix_tracks_play_count ON tracks(play_count);
        CREATE INDEX ix_tracks_title ON tracks(title COLLATE NOCASE);

        CREATE VIRTUAL TABLE tracks_fts USING fts5(
            title, artist, album, album_artist, genre, composer, path,
            tokenize = "unicode61 remove_diacritics 2",
            prefix = '1 2 3'
        );

        CREATE TRIGGER tracks_ai AFTER INSERT ON tracks BEGIN
            INSERT INTO tracks_fts(rowid, title, artist, album, album_artist, genre, composer, path)
            VALUES (new.id, new.title, new.artist, new.album, new.album_artist, new.genre, new.composer, coalesce(new.file_path, new.source_uri));
        END;
        CREATE TRIGGER tracks_ad AFTER DELETE ON tracks BEGIN
            DELETE FROM tracks_fts WHERE rowid = old.id;
        END;
        CREATE TRIGGER tracks_au AFTER UPDATE OF title, artist, album, album_artist, genre, composer, file_path, source_uri ON tracks BEGIN
            DELETE FROM tracks_fts WHERE rowid = old.id;
            INSERT INTO tracks_fts(rowid, title, artist, album, album_artist, genre, composer, path)
            VALUES (new.id, new.title, new.artist, new.album, new.album_artist, new.genre, new.composer, coalesce(new.file_path, new.source_uri));
        END;

        CREATE VIEW albums AS
            SELECT album_key,
                   max(album) AS name,
                   max(coalesce(nullif(album_artist, ''), artist)) AS album_artist,
                   max(year) AS year,
                   max(genre) AS genre,
                   count(*) AS track_count,
                   count(DISTINCT coalesce(disc_number, 1)) AS disc_count,
                   sum(duration_ms) AS duration_ms,
                   max(artwork_hash) AS artwork_hash,
                   max(bit_depth) AS max_bit_depth,
                   max(sample_rate) AS max_sample_rate,
                   max(codec) AS codec,
                   min(date_added) AS date_added,
                   sum(play_count) AS play_count
            FROM tracks
            WHERE album IS NOT NULL AND album <> ''
            GROUP BY album_key;

        CREATE TABLE playlists (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            kind TEXT NOT NULL DEFAULT 'Normal',
            smart_json TEXT NULL,
            sort_order INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        );

        CREATE TABLE playlist_items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            playlist_id INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
            position INTEGER NOT NULL,
            track_id INTEGER NULL REFERENCES tracks(id) ON DELETE SET NULL,
            source_uri TEXT NOT NULL,
            cue_start_ms INTEGER NOT NULL DEFAULT 0,
            title TEXT NULL,
            artist TEXT NULL,
            duration_ms INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX ix_playlist_items ON playlist_items(playlist_id, position);
        CREATE INDEX ix_playlist_items_uri ON playlist_items(source_uri);

        CREATE TABLE bookmarks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            track_id INTEGER NULL REFERENCES tracks(id) ON DELETE SET NULL,
            source_uri TEXT NOT NULL,
            cue_start_ms INTEGER NOT NULL DEFAULT 0,
            position_ms INTEGER NOT NULL,
            note TEXT NULL,
            title TEXT NULL,
            artist TEXT NULL,
            created_at INTEGER NOT NULL
        );
        CREATE INDEX ix_bookmarks_uri ON bookmarks(source_uri, cue_start_ms);

        CREATE TABLE play_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            track_id INTEGER NULL REFERENCES tracks(id) ON DELETE SET NULL,
            source_uri TEXT NOT NULL,
            title TEXT NULL,
            artist TEXT NULL,
            played_at INTEGER NOT NULL,
            played_ms INTEGER NOT NULL DEFAULT 0,
            completed INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX ix_play_history_time ON play_history(played_at DESC);

        CREATE TABLE downloads (
            id TEXT PRIMARY KEY,
            source_uri TEXT NOT NULL,
            track_id INTEGER NULL,
            title TEXT NOT NULL DEFAULT '',
            artist TEXT NULL,
            destination TEXT NOT NULL,
            total_bytes INTEGER NOT NULL DEFAULT 0,
            downloaded_bytes INTEGER NOT NULL DEFAULT 0,
            state TEXT NOT NULL,
            kind TEXT NOT NULL,
            error TEXT NULL,
            attempts INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        );

        CREATE TABLE eq_presets (
            name TEXT PRIMARY KEY COLLATE NOCASE,
            preamp_db REAL NOT NULL DEFAULT 0,
            bands_json TEXT NOT NULL,
            updated_at INTEGER NOT NULL
        );

        CREATE TABLE dsp_chains (
            name TEXT PRIMARY KEY COLLATE NOCASE,
            chain_json TEXT NOT NULL,
            updated_at INTEGER NOT NULL
        );

        CREATE TABLE settings (
            key TEXT PRIMARY KEY,
            value TEXT NULL
        );

        CREATE TABLE audio_cache (
            source_uri TEXT PRIMARY KEY,
            path TEXT NOT NULL,
            size INTEGER NOT NULL,
            last_access INTEGER NOT NULL
        );
        CREATE INDEX ix_audio_cache_access ON audio_cache(last_access);
        """
    };
}
