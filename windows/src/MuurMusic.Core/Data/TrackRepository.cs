using System.Text;
using Microsoft.Data.Sqlite;
using MuurMusic.Core.Models;
using MuurMusic.Core.Playlists;

namespace MuurMusic.Core.Data;

/// <summary>Track storage, browse/sort queries, aggregates, user data (ratings, favorites, plays) and play history.</summary>
public interface ITrackRepository
{
    Task<IReadOnlyList<Track>> QueryAsync(TrackQuery query, CancellationToken ct = default);
    Task<int> CountAsync(TrackQuery query, CancellationToken ct = default);
    Task<Track?> GetByIdAsync(long id, CancellationToken ct = default);
    Task<IReadOnlyList<Track>> GetByIdsAsync(IEnumerable<long> ids, CancellationToken ct = default);
    Task<Track?> GetBySourceUriAsync(string sourceUri, long cueStartMs = 0, CancellationToken ct = default);
    Task<IReadOnlyList<Track>> GetByFilePathAsync(string filePath, CancellationToken ct = default);

    Task<IReadOnlyList<Album>> GetAlbumsAsync(AlbumQuery query, CancellationToken ct = default);
    Task<Album?> GetAlbumAsync(string albumKey, CancellationToken ct = default);
    Task<IReadOnlyList<Track>> GetAlbumTracksAsync(string albumKey, CancellationToken ct = default);
    Task<IReadOnlyList<Artist>> GetArtistsAsync(bool albumArtists, string? search = null, bool availableOnly = false, CancellationToken ct = default);
    Task<IReadOnlyList<Genre>> GetGenresAsync(bool availableOnly = false, CancellationToken ct = default);
    Task<IReadOnlyList<Composer>> GetComposersAsync(bool availableOnly = false, CancellationToken ct = default);
    Task<FolderContents> GetFolderContentsAsync(string folderPath, TrackSortField sort = TrackSortField.FileName, bool availableOnly = false, CancellationToken ct = default);
    Task<IReadOnlyList<LibraryFolder>> GetRootFoldersAsync(IEnumerable<string> roots, CancellationToken ct = default);
    Task<LibraryStats> GetStatsAsync(CancellationToken ct = default);

    Task<IReadOnlyList<Track>> GetRecentlyPlayedAsync(int limit = 50, bool availableOnly = false, CancellationToken ct = default);
    Task<IReadOnlyList<Track>> GetRecentlyAddedAsync(int limit = 50, bool availableOnly = false, CancellationToken ct = default);
    Task<IReadOnlyList<Track>> GetMostPlayedAsync(int limit = 50, bool availableOnly = false, CancellationToken ct = default);
    Task<IReadOnlyList<Track>> GetFavoritesAsync(TrackSortField sort = TrackSortField.Artist, bool availableOnly = false, CancellationToken ct = default);
    Task<IReadOnlyList<Track>> QuerySmartAsync(SmartPlaylistDefinition definition, bool availableOnly = false, CancellationToken ct = default);

    /// <summary>Inserts or updates tracks keyed by (source_uri, cue_start_ms). User data (rating, plays, favorite, date added) is preserved on update.</summary>
    Task<IReadOnlyList<long>> UpsertAsync(IReadOnlyList<Track> tracks, CancellationToken ct = default);
    /// <summary>Updates tag columns of existing rows (after tag editing).</summary>
    Task UpdateTagsAsync(IReadOnlyList<Track> tracks, CancellationToken ct = default);
    Task DeleteAsync(IEnumerable<long> ids, CancellationToken ct = default);
    Task<int> DeleteByFilePathsAsync(IEnumerable<string> filePaths, CancellationToken ct = default);
    /// <summary>Deletes CUE virtual tracks for <paramref name="sourceUri"/> whose start offset is not in <paramref name="keepCueStarts"/>.</summary>
    Task DeleteStaleCueTracksAsync(string sourceUri, IReadOnlyCollection<long> keepCueStarts, CancellationToken ct = default);
    /// <summary>file path → (mtime ms, size) for all local tracks below <paramref name="folderPrefix"/>.</summary>
    Task<Dictionary<string, (long Mtime, long Size)>> GetFileIndexAsync(string folderPrefix, CancellationToken ct = default);

    Task SetRatingAsync(long trackId, int rating, CancellationToken ct = default);
    Task SetFavoriteAsync(long trackId, bool favorite, CancellationToken ct = default);
    Task SetLocalCopyAsync(string sourceUri, string? localPath, CancellationToken ct = default);
    Task SetArtworkAsync(IEnumerable<long> trackIds, string? artworkHash, CancellationToken ct = default);
    Task SetHasLyricsAsync(long trackId, bool hasLyrics, CancellationToken ct = default);
    /// <summary>Increments play count / last played (library tracks) and appends a history entry.</summary>
    Task RecordPlayAsync(Track track, long playedMs, bool completed, CancellationToken ct = default);
    Task RecordSkipAsync(long trackId, CancellationToken ct = default);
    Task<IReadOnlyList<PlayHistoryEntry>> GetHistoryAsync(int limit = 200, int offset = 0, CancellationToken ct = default);
    Task ClearHistoryAsync(CancellationToken ct = default);
}

public sealed class TrackRepository(LibraryDatabase db) : ITrackRepository
{
    internal const string Columns =
        "t.id, t.source_uri, t.source_id, t.file_path, t.folder, t.file_name, t.cue_start_ms, t.cue_end_ms, t.cue_sheet_path, " +
        "t.title, t.artist, t.album, t.album_artist, t.genre, t.composer, t.year, t.track_number, t.track_total, t.disc_number, t.disc_total, " +
        "t.bpm, t.comment, t.has_lyrics, t.rating, t.play_count, t.skip_count, t.last_played, t.date_added, t.favorite, t.duration_ms, " +
        "t.bitrate, t.sample_rate, t.bit_depth, t.channels, t.codec, t.format, t.file_size, t.file_mtime, t.artwork_hash, " +
        "t.rg_track_gain, t.rg_track_peak, t.rg_album_gain, t.rg_album_peak, t.is_remote, t.local_copy_path, t.mb_recording_id, t.mb_release_id, t.unavailable, t.artwork_url";

    internal static Track Map(SqliteDataReader r) => Map(r, 0);

    internal static Track Map(SqliteDataReader r, int o) => new()
    {
        Id = r.GetInt64(o + 0),
        SourceUri = r.GetString(o + 1),
        SourceId = r.IsDBNull(o + 2) ? null : Guid.Parse(r.GetString(o + 2)),
        FilePath = r.Str(o + 3),
        Folder = r.Str(o + 4),
        FileName = r.Str(o + 5) ?? "",
        CueStartMs = r.Long(o + 6),
        CueEndMs = r.LongN(o + 7),
        CueSheetPath = r.Str(o + 8),
        Title = r.Str(o + 9),
        Artist = r.Str(o + 10),
        Album = r.Str(o + 11),
        AlbumArtist = r.Str(o + 12),
        Genre = r.Str(o + 13),
        Composer = r.Str(o + 14),
        Year = r.IntN(o + 15),
        TrackNumber = r.IntN(o + 16),
        TrackTotal = r.IntN(o + 17),
        DiscNumber = r.IntN(o + 18),
        DiscTotal = r.IntN(o + 19),
        Bpm = r.IntN(o + 20),
        Comment = r.Str(o + 21),
        HasLyrics = r.Bool(o + 22),
        Rating = r.Int(o + 23),
        PlayCount = r.Int(o + 24),
        SkipCount = r.Int(o + 25),
        LastPlayed = r.DateN(o + 26),
        DateAdded = r.Date(o + 27),
        Favorite = r.Bool(o + 28),
        DurationMs = r.Long(o + 29),
        Bitrate = r.Int(o + 30),
        SampleRate = r.Int(o + 31),
        BitDepth = r.Int(o + 32),
        Channels = r.Int(o + 33),
        Codec = r.Str(o + 34),
        Format = r.Str(o + 35),
        FileSize = r.Long(o + 36),
        FileModifiedMs = r.Long(o + 37),
        ArtworkHash = r.Str(o + 38),
        ReplayGainTrackGain = r.DoubleN(o + 39),
        ReplayGainTrackPeak = r.DoubleN(o + 40),
        ReplayGainAlbumGain = r.DoubleN(o + 41),
        ReplayGainAlbumPeak = r.DoubleN(o + 42),
        IsRemote = r.Bool(o + 43),
        LocalCopyPath = r.Str(o + 44),
        MusicBrainzRecordingId = r.Str(o + 45),
        MusicBrainzReleaseId = r.Str(o + 46),
        IsUnavailable = r.Bool(o + 47),
        ArtworkUrl = r.Str(o + 48)
    };

    public static string AlbumKeyFor(Track t)
    {
        var artist = (string.IsNullOrWhiteSpace(t.AlbumArtist) ? t.Artist : t.AlbumArtist)?.Trim().ToLowerInvariant() ?? "";
        var album = t.Album?.Trim().ToLowerInvariant() ?? "";
        return album.Length == 0 ? "" : artist + "\u001f" + album;
    }

    private static (string Where, Dictionary<string, object?> Args) BuildWhere(TrackQuery q)
    {
        var where = new List<string>();
        var args = new Dictionary<string, object?>();
        var fts = TrackSql.BuildFtsQuery(q.Search);
        if (fts is not null)
        {
            where.Add("t.id IN (SELECT rowid FROM tracks_fts WHERE tracks_fts MATCH @fts)");
            args["fts"] = fts;
        }
        if (q.Artist is not null) { where.Add("t.artist = @artist COLLATE NOCASE"); args["artist"] = q.Artist; }
        if (q.AlbumArtist is not null) { where.Add("coalesce(nullif(t.album_artist, ''), t.artist) = @albumArtist COLLATE NOCASE"); args["albumArtist"] = q.AlbumArtist; }
        if (q.AlbumKey is not null) { where.Add("t.album_key = @albumKey"); args["albumKey"] = q.AlbumKey; }
        if (q.Genre is not null) { where.Add("t.genre = @genre COLLATE NOCASE"); args["genre"] = q.Genre; }
        if (q.Composer is not null) { where.Add("t.composer = @composer COLLATE NOCASE"); args["composer"] = q.Composer; }
        if (q.Folder is not null)
        {
            var folder = q.Folder.TrimEnd('\\', '/');
            if (q.IncludeSubfolders)
            {
                where.Add("(t.folder = @folder COLLATE NOCASE OR t.folder LIKE @folderLike ESCAPE '^')");
                args["folderLike"] = Db.EscapeLike(folder + Path.DirectorySeparatorChar) + "%";
            }
            else where.Add("t.folder = @folder COLLATE NOCASE");
            args["folder"] = folder;
        }
        if (q.FavoritesOnly) where.Add("t.favorite = 1");
        if (q.MinRating is { } mr) { where.Add("t.rating >= @minRating"); args["minRating"] = mr; }
        if (q.SourceId is { } sid) { where.Add("t.source_id = @sourceId"); args["sourceId"] = sid.ToString("D"); }
        if (q.AvailableOnly) where.Add(TrackSql.AvailableFilter);
        return (where.Count == 0 ? "1 = 1" : string.Join(" AND ", where), args);
    }

    public async Task<IReadOnlyList<Track>> QueryAsync(TrackQuery query, CancellationToken ct = default)
    {
        var (where, args) = BuildWhere(query);
        var sql = new StringBuilder($"SELECT {Columns} FROM tracks t WHERE {where} ORDER BY {TrackSql.OrderBy(query.Sort, query.Descending)}");
        if (query.Limit > 0) sql.Append($" LIMIT {query.Limit} OFFSET {Math.Max(0, query.Offset)}");
        else if (query.Offset > 0) sql.Append($" LIMIT -1 OFFSET {query.Offset}");
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        return await c.QueryAsync(sql.ToString(), Map, args, ct).ConfigureAwait(false);
    }

    public async Task<int> CountAsync(TrackQuery query, CancellationToken ct = default)
    {
        var (where, args) = BuildWhere(query);
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        return await c.ScalarAsync<int>($"SELECT count(*) FROM tracks t WHERE {where}", args, ct).ConfigureAwait(false);
    }

    public async Task<Track?> GetByIdAsync(long id, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        return (await c.QueryAsync($"SELECT {Columns} FROM tracks t WHERE t.id = @id", Map, new { id }, ct).ConfigureAwait(false)).FirstOrDefault();
    }

    public async Task<IReadOnlyList<Track>> GetByIdsAsync(IEnumerable<long> ids, CancellationToken ct = default)
    {
        var list = ids.Distinct().ToList();
        if (list.Count == 0) return Array.Empty<Track>();
        var result = new Dictionary<long, Track>();
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        foreach (var chunk in list.Chunk(500))
        {
            var rows = await c.QueryAsync($"SELECT {Columns} FROM tracks t WHERE t.id IN ({string.Join(',', chunk)})", Map, null, ct).ConfigureAwait(false);
            foreach (var t in rows) result[t.Id] = t;
        }
        return ids.Where(result.ContainsKey).Select(id => result[id]).ToList();
    }

    public async Task<Track?> GetBySourceUriAsync(string sourceUri, long cueStartMs = 0, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        return (await c.QueryAsync($"SELECT {Columns} FROM tracks t WHERE t.source_uri = @sourceUri AND t.cue_start_ms = @cueStartMs", Map, new { sourceUri, cueStartMs }, ct).ConfigureAwait(false)).FirstOrDefault();
    }

    public async Task<IReadOnlyList<Track>> GetByFilePathAsync(string filePath, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        return await c.QueryAsync($"SELECT {Columns} FROM tracks t WHERE t.file_path = @filePath COLLATE NOCASE ORDER BY t.cue_start_ms", Map, new { filePath }, ct).ConfigureAwait(false);
    }

    private static Album MapAlbum(SqliteDataReader r) => new(
        r.GetString(0), r.Str(1) ?? "", r.Str(2) ?? "Unknown artist", r.IntN(3), r.Str(4), r.Int(5), r.Int(6), r.Long(7), r.Str(8),
        r.Int(9), r.Int(10), r.Str(11), r.Date(12), r.Int(13));

    private const string AlbumSelect =
        "SELECT t.album_key, max(t.album), max(coalesce(nullif(t.album_artist, ''), t.artist)), max(t.year), max(t.genre), count(*), " +
        "count(DISTINCT coalesce(t.disc_number, 1)), sum(t.duration_ms), max(t.artwork_hash), max(t.bit_depth), max(t.sample_rate), max(t.codec), min(t.date_added), sum(t.play_count) FROM tracks t";

    public async Task<IReadOnlyList<Album>> GetAlbumsAsync(AlbumQuery query, CancellationToken ct = default)
    {
        var where = new List<string> { "t.album_key <> ''" };
        var args = new Dictionary<string, object?>();
        var fts = TrackSql.BuildFtsQuery(query.Search);
        if (fts is not null) { where.Add("t.id IN (SELECT rowid FROM tracks_fts WHERE tracks_fts MATCH @fts)"); args["fts"] = fts; }
        if (query.Artist is not null)
        {
            where.Add("t.album_key IN (SELECT album_key FROM tracks WHERE artist = @artist COLLATE NOCASE OR album_artist = @artist COLLATE NOCASE)");
            args["artist"] = query.Artist;
        }
        if (query.Genre is not null) { where.Add("t.genre = @genre COLLATE NOCASE"); args["genre"] = query.Genre; }
        if (query.Composer is not null) { where.Add("t.composer = @composer COLLATE NOCASE"); args["composer"] = query.Composer; }
        if (query.AvailableOnly) where.Add(TrackSql.AvailableFilter);
        var d = query.Descending ? " DESC" : "";
        var order = query.Sort switch
        {
            AlbumSortField.Artist => $"3 COLLATE NOCASE{d}, 4, 2 COLLATE NOCASE",
            AlbumSortField.Year => $"4 IS NULL, 4{d}, 2 COLLATE NOCASE",
            AlbumSortField.DateAdded => $"13{d}",
            AlbumSortField.PlayCount => $"14{d}, 2 COLLATE NOCASE",
            AlbumSortField.Duration => $"8{d}",
            AlbumSortField.Random => "random()",
            _ => $"2 COLLATE NOCASE{d}, 3 COLLATE NOCASE"
        };
        var sql = $"{AlbumSelect} WHERE {string.Join(" AND ", where)} GROUP BY t.album_key ORDER BY {order}";
        if (query.Limit > 0) sql += $" LIMIT {query.Limit} OFFSET {Math.Max(0, query.Offset)}";
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        return await c.QueryAsync(sql, MapAlbum, args, ct).ConfigureAwait(false);
    }

    public async Task<Album?> GetAlbumAsync(string albumKey, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        return (await c.QueryAsync($"{AlbumSelect} WHERE t.album_key = @albumKey GROUP BY t.album_key", MapAlbum, new { albumKey }, ct).ConfigureAwait(false)).FirstOrDefault();
    }

    public Task<IReadOnlyList<Track>> GetAlbumTracksAsync(string albumKey, CancellationToken ct = default) =>
        QueryAsync(new TrackQuery { AlbumKey = albumKey, Sort = TrackSortField.TrackNumber }, ct);

    public async Task<IReadOnlyList<Artist>> GetArtistsAsync(bool albumArtists, string? search = null, bool availableOnly = false, CancellationToken ct = default)
    {
        var col = albumArtists ? "coalesce(nullif(t.album_artist, ''), t.artist)" : "t.artist";
        var where = new List<string> { $"{col} IS NOT NULL AND {col} <> ''" };
        var args = new Dictionary<string, object?>();
        var fts = TrackSql.BuildFtsQuery(search);
        if (fts is not null) { where.Add("t.id IN (SELECT rowid FROM tracks_fts WHERE tracks_fts MATCH @fts)"); args["fts"] = fts; }
        if (availableOnly) where.Add(TrackSql.AvailableFilter);
        var sql = $"SELECT max({col}), count(DISTINCT nullif(t.album_key, '')), count(*), sum(t.duration_ms), max(t.artwork_hash) FROM tracks t " +
                  $"WHERE {string.Join(" AND ", where)} GROUP BY {col} COLLATE NOCASE ORDER BY 1 COLLATE NOCASE";
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        return await c.QueryAsync(sql, r => new Artist(r.GetString(0), r.Int(1), r.Int(2), r.Long(3), r.Str(4)), args, ct).ConfigureAwait(false);
    }

    public async Task<IReadOnlyList<Genre>> GetGenresAsync(bool availableOnly = false, CancellationToken ct = default)
    {
        var avail = availableOnly ? " AND " + TrackSql.AvailableFilter : "";
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        return await c.QueryAsync(
            $"SELECT max(t.genre), count(DISTINCT nullif(t.album_key, '')), count(*), max(t.artwork_hash) FROM tracks t WHERE t.genre IS NOT NULL AND t.genre <> ''{avail} GROUP BY t.genre COLLATE NOCASE ORDER BY 1 COLLATE NOCASE",
            r => new Genre(r.GetString(0), r.Int(1), r.Int(2), r.Str(3)), null, ct).ConfigureAwait(false);
    }

    public async Task<IReadOnlyList<Composer>> GetComposersAsync(bool availableOnly = false, CancellationToken ct = default)
    {
        var avail = availableOnly ? " AND " + TrackSql.AvailableFilter : "";
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        return await c.QueryAsync(
            $"SELECT max(t.composer), count(DISTINCT nullif(t.album_key, '')), count(*), max(t.artwork_hash) FROM tracks t WHERE t.composer IS NOT NULL AND t.composer <> ''{avail} GROUP BY t.composer COLLATE NOCASE ORDER BY 1 COLLATE NOCASE",
            r => new Composer(r.GetString(0), r.Int(1), r.Int(2), r.Str(3)), null, ct).ConfigureAwait(false);
    }

    public async Task<FolderContents> GetFolderContentsAsync(string folderPath, TrackSortField sort = TrackSortField.FileName, bool availableOnly = false, CancellationToken ct = default)
    {
        var folder = folderPath.TrimEnd('\\', '/');
        var prefix = folder + Path.DirectorySeparatorChar;
        var avail = availableOnly ? " AND " + TrackSql.AvailableFilter : "";
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        var sub = await c.QueryAsync(
            $"SELECT t.folder, count(*) FROM tracks t WHERE t.folder LIKE @like ESCAPE '^'{avail} GROUP BY t.folder",
            r => (Folder: r.GetString(0), Count: r.Int(1)), new { like = Db.EscapeLike(prefix) + "%" }, ct).ConfigureAwait(false);
        var children = new Dictionary<string, (int Count, bool HasSub)>(StringComparer.OrdinalIgnoreCase);
        foreach (var (f, count) in sub)
        {
            var rest = f[prefix.Length..];
            var sep = rest.IndexOf(Path.DirectorySeparatorChar);
            var name = sep < 0 ? rest : rest[..sep];
            if (name.Length == 0) continue;
            children.TryGetValue(name, out var existing);
            children[name] = (existing.Count + count, existing.HasSub || sep >= 0);
        }
        var folders = children.OrderBy(k => k.Key, StringComparer.CurrentCultureIgnoreCase)
            .Select(k => new LibraryFolder(prefix + k.Key, k.Key, k.Value.Count, k.Value.HasSub)).ToList();
        var tracks = await QueryAsync(new TrackQuery { Folder = folder, Sort = sort, AvailableOnly = availableOnly }, ct).ConfigureAwait(false);
        return new FolderContents(folder, folders, tracks);
    }

    public async Task<IReadOnlyList<LibraryFolder>> GetRootFoldersAsync(IEnumerable<string> roots, CancellationToken ct = default)
    {
        var result = new List<LibraryFolder>();
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        foreach (var root in roots.Select(r => r.TrimEnd('\\', '/')).Distinct(StringComparer.OrdinalIgnoreCase))
        {
            var count = await c.ScalarAsync<int>("SELECT count(*) FROM tracks WHERE folder = @root COLLATE NOCASE OR folder LIKE @like ESCAPE '^'",
                new { root, like = Db.EscapeLike(root + Path.DirectorySeparatorChar) + "%" }, ct).ConfigureAwait(false);
            var hasSub = await c.ScalarAsync<int>("SELECT count(*) FROM (SELECT 1 FROM tracks WHERE folder LIKE @like ESCAPE '^' LIMIT 1)",
                new { like = Db.EscapeLike(root + Path.DirectorySeparatorChar) + "%" }, ct).ConfigureAwait(false) > 0;
            var name = Path.GetFileName(root);
            result.Add(new LibraryFolder(root, string.IsNullOrEmpty(name) ? root : name, count, hasSub));
        }
        return result;
    }

    public async Task<LibraryStats> GetStatsAsync(CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        var rows = await c.QueryAsync(
            "SELECT count(*), count(DISTINCT nullif(album_key, '')), count(DISTINCT lower(artist)), coalesce(sum(duration_ms), 0), coalesce(sum(CASE WHEN cue_start_ms = 0 THEN file_size ELSE 0 END), 0) FROM tracks",
            r => new LibraryStats(r.Int(0), r.Int(1), r.Int(2), r.Long(3), r.Long(4)), null, ct).ConfigureAwait(false);
        return rows[0];
    }

    public Task<IReadOnlyList<Track>> GetRecentlyPlayedAsync(int limit = 50, bool availableOnly = false, CancellationToken ct = default) =>
        QueryWhereAsync("t.last_played IS NOT NULL", "t.last_played DESC", limit, availableOnly, ct);

    public Task<IReadOnlyList<Track>> GetRecentlyAddedAsync(int limit = 50, bool availableOnly = false, CancellationToken ct = default) =>
        QueryWhereAsync("1 = 1", "t.date_added DESC, t.album_key, coalesce(t.disc_number, 1), coalesce(t.track_number, 0)", limit, availableOnly, ct);

    public Task<IReadOnlyList<Track>> GetMostPlayedAsync(int limit = 50, bool availableOnly = false, CancellationToken ct = default) =>
        QueryWhereAsync("t.play_count > 0", "t.play_count DESC, t.last_played DESC", limit, availableOnly, ct);

    public Task<IReadOnlyList<Track>> GetFavoritesAsync(TrackSortField sort = TrackSortField.Artist, bool availableOnly = false, CancellationToken ct = default) =>
        QueryAsync(new TrackQuery { FavoritesOnly = true, Sort = sort, AvailableOnly = availableOnly }, ct);

    private async Task<IReadOnlyList<Track>> QueryWhereAsync(string where, string order, int limit, bool availableOnly, CancellationToken ct)
    {
        if (availableOnly) where += " AND " + TrackSql.AvailableFilter;
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        return await c.QueryAsync($"SELECT {Columns} FROM tracks t WHERE {where} ORDER BY {order} LIMIT {Math.Max(1, limit)}", Map, null, ct).ConfigureAwait(false);
    }

    public async Task<IReadOnlyList<Track>> QuerySmartAsync(SmartPlaylistDefinition definition, bool availableOnly = false, CancellationToken ct = default)
    {
        var compiled = SmartPlaylistCompiler.Compile(definition, availableOnly: availableOnly);
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        return await c.QueryAsync(compiled.ToSelectSql(Columns), Map, compiled.Parameters, ct).ConfigureAwait(false);
    }

    private const string UpsertSql = """
        INSERT INTO tracks (source_uri, source_id, file_path, folder, file_name, cue_start_ms, cue_end_ms, cue_sheet_path, title, artist, album, album_artist, album_key,
            genre, composer, year, track_number, track_total, disc_number, disc_total, bpm, comment, has_lyrics, rating, play_count, skip_count, last_played, date_added,
            favorite, duration_ms, bitrate, sample_rate, bit_depth, channels, codec, format, file_size, file_mtime, artwork_hash, rg_track_gain, rg_track_peak,
            rg_album_gain, rg_album_peak, is_remote, local_copy_path, mb_recording_id, mb_release_id, unavailable, artwork_url)
        VALUES (@source_uri, @source_id, @file_path, @folder, @file_name, @cue_start_ms, @cue_end_ms, @cue_sheet_path, @title, @artist, @album, @album_artist, @album_key,
            @genre, @composer, @year, @track_number, @track_total, @disc_number, @disc_total, @bpm, @comment, @has_lyrics, @rating, @play_count, @skip_count, @last_played, @date_added,
            @favorite, @duration_ms, @bitrate, @sample_rate, @bit_depth, @channels, @codec, @format, @file_size, @file_mtime, @artwork_hash, @rg_track_gain, @rg_track_peak,
            @rg_album_gain, @rg_album_peak, @is_remote, @local_copy_path, @mb_recording_id, @mb_release_id, 0, @artwork_url)
        ON CONFLICT (source_uri, cue_start_ms) DO UPDATE SET
            source_id = excluded.source_id, file_path = excluded.file_path, folder = excluded.folder, file_name = excluded.file_name, cue_end_ms = excluded.cue_end_ms,
            cue_sheet_path = excluded.cue_sheet_path, title = excluded.title, artist = excluded.artist, album = excluded.album, album_artist = excluded.album_artist,
            album_key = excluded.album_key, genre = excluded.genre, composer = excluded.composer, year = excluded.year, track_number = excluded.track_number,
            track_total = excluded.track_total, disc_number = excluded.disc_number, disc_total = excluded.disc_total, bpm = excluded.bpm, comment = excluded.comment,
            has_lyrics = excluded.has_lyrics, duration_ms = excluded.duration_ms, bitrate = excluded.bitrate, sample_rate = excluded.sample_rate,
            bit_depth = excluded.bit_depth, channels = excluded.channels, codec = excluded.codec, format = excluded.format, file_size = excluded.file_size,
            file_mtime = excluded.file_mtime, artwork_hash = coalesce(excluded.artwork_hash, tracks.artwork_hash), rg_track_gain = excluded.rg_track_gain,
            rg_track_peak = excluded.rg_track_peak, rg_album_gain = excluded.rg_album_gain, rg_album_peak = excluded.rg_album_peak, is_remote = excluded.is_remote,
            mb_recording_id = coalesce(excluded.mb_recording_id, tracks.mb_recording_id), mb_release_id = coalesce(excluded.mb_release_id, tracks.mb_release_id),
            unavailable = 0, artwork_url = coalesce(excluded.artwork_url, tracks.artwork_url)
        RETURNING id;
        """;

    public async Task<IReadOnlyList<long>> UpsertAsync(IReadOnlyList<Track> tracks, CancellationToken ct = default)
    {
        var ids = new List<long>(tracks.Count);
        if (tracks.Count == 0) return ids;
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        await using var tx = (SqliteTransaction)await c.BeginTransactionAsync(ct).ConfigureAwait(false);
        await using var cmd = c.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandText = UpsertSql;
        foreach (var t in tracks)
        {
            ct.ThrowIfCancellationRequested();
            cmd.Parameters.Clear();
            BindTrack(cmd, t);
            var id = (long)(await cmd.ExecuteScalarAsync(ct).ConfigureAwait(false))!;
            t.Id = id;
            ids.Add(id);
        }
        await tx.CommitAsync(ct).ConfigureAwait(false);
        return ids;
    }

    private static void BindTrack(SqliteCommand cmd, Track t)
    {
        void P(string n, object? v) => cmd.Parameters.AddWithValue("@" + n, Db.ToDb(v));
        P("source_uri", t.SourceUri); P("source_id", t.SourceId); P("file_path", t.FilePath); P("folder", t.Folder); P("file_name", t.FileName);
        P("cue_start_ms", t.CueStartMs); P("cue_end_ms", t.CueEndMs); P("cue_sheet_path", t.CueSheetPath);
        P("title", t.Title); P("artist", t.Artist); P("album", t.Album); P("album_artist", t.AlbumArtist); P("album_key", AlbumKeyFor(t));
        P("genre", t.Genre); P("composer", t.Composer); P("year", t.Year); P("track_number", t.TrackNumber); P("track_total", t.TrackTotal);
        P("disc_number", t.DiscNumber); P("disc_total", t.DiscTotal); P("bpm", t.Bpm); P("comment", t.Comment); P("has_lyrics", t.HasLyrics);
        P("rating", Math.Clamp(t.Rating, 0, 5)); P("play_count", t.PlayCount); P("skip_count", t.SkipCount); P("last_played", t.LastPlayed); P("date_added", t.DateAdded);
        P("favorite", t.Favorite); P("duration_ms", t.DurationMs); P("bitrate", t.Bitrate); P("sample_rate", t.SampleRate); P("bit_depth", t.BitDepth);
        P("channels", t.Channels); P("codec", t.Codec); P("format", t.Format); P("file_size", t.FileSize); P("file_mtime", t.FileModifiedMs);
        P("artwork_hash", t.ArtworkHash); P("rg_track_gain", t.ReplayGainTrackGain); P("rg_track_peak", t.ReplayGainTrackPeak);
        P("rg_album_gain", t.ReplayGainAlbumGain); P("rg_album_peak", t.ReplayGainAlbumPeak); P("is_remote", t.IsRemote); P("local_copy_path", t.LocalCopyPath);
        P("mb_recording_id", t.MusicBrainzRecordingId); P("mb_release_id", t.MusicBrainzReleaseId); P("artwork_url", t.ArtworkUrl);
    }

    public async Task UpdateTagsAsync(IReadOnlyList<Track> tracks, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        await using var tx = (SqliteTransaction)await c.BeginTransactionAsync(ct).ConfigureAwait(false);
        foreach (var t in tracks)
        {
            await c.ExecAsync("""
                UPDATE tracks SET title=@Title, artist=@Artist, album=@Album, album_artist=@AlbumArtist, album_key=@AlbumKey, genre=@Genre, composer=@Composer,
                    year=@Year, track_number=@TrackNumber, track_total=@TrackTotal, disc_number=@DiscNumber, disc_total=@DiscTotal, bpm=@Bpm, comment=@Comment,
                    has_lyrics=@HasLyrics, artwork_hash=@ArtworkHash, file_mtime=@FileModifiedMs, file_size=@FileSize, mb_recording_id=@MusicBrainzRecordingId,
                    mb_release_id=@MusicBrainzReleaseId, rating=@Rating
                WHERE id=@Id
                """, new
            {
                t.Title, t.Artist, t.Album, t.AlbumArtist, AlbumKey = AlbumKeyFor(t), t.Genre, t.Composer, t.Year, t.TrackNumber, t.TrackTotal, t.DiscNumber,
                t.DiscTotal, t.Bpm, t.Comment, t.HasLyrics, t.ArtworkHash, t.FileModifiedMs, t.FileSize, t.MusicBrainzRecordingId, t.MusicBrainzReleaseId,
                Rating = Math.Clamp(t.Rating, 0, 5), t.Id
            }, ct, tx).ConfigureAwait(false);
        }
        await tx.CommitAsync(ct).ConfigureAwait(false);
    }

    public async Task DeleteAsync(IEnumerable<long> ids, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        foreach (var chunk in ids.Chunk(500))
            await c.ExecAsync($"DELETE FROM tracks WHERE id IN ({string.Join(',', chunk)})", null, ct).ConfigureAwait(false);
    }

    public async Task<int> DeleteByFilePathsAsync(IEnumerable<string> filePaths, CancellationToken ct = default)
    {
        var n = 0;
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        await using var tx = (SqliteTransaction)await c.BeginTransactionAsync(ct).ConfigureAwait(false);
        foreach (var p in filePaths)
            n += await c.ExecAsync("DELETE FROM tracks WHERE file_path = @p COLLATE NOCASE OR cue_sheet_path = @p COLLATE NOCASE", new { p }, ct, tx).ConfigureAwait(false);
        await tx.CommitAsync(ct).ConfigureAwait(false);
        return n;
    }

    public async Task DeleteStaleCueTracksAsync(string sourceUri, IReadOnlyCollection<long> keepCueStarts, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        var keep = keepCueStarts.Count == 0 ? "-1" : string.Join(',', keepCueStarts);
        await c.ExecAsync($"DELETE FROM tracks WHERE source_uri = @sourceUri AND cue_start_ms NOT IN ({keep})", new { sourceUri }, ct).ConfigureAwait(false);
    }

    public async Task<Dictionary<string, (long Mtime, long Size)>> GetFileIndexAsync(string folderPrefix, CancellationToken ct = default)
    {
        var root = folderPrefix.TrimEnd('\\', '/');
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        var rows = await c.QueryAsync(
            "SELECT file_path, max(file_mtime), max(file_size) FROM tracks WHERE is_remote = 0 AND file_path IS NOT NULL AND (folder = @root COLLATE NOCASE OR folder LIKE @like ESCAPE '^') GROUP BY file_path",
            r => (Path: r.GetString(0), Mtime: r.Long(1), Size: r.Long(2)), new { root, like = Db.EscapeLike(root + Path.DirectorySeparatorChar) + "%" }, ct).ConfigureAwait(false);
        var d = new Dictionary<string, (long, long)>(StringComparer.OrdinalIgnoreCase);
        foreach (var row in rows) d[row.Path] = (row.Mtime, row.Size);
        return d;
    }

    public async Task SetRatingAsync(long trackId, int rating, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        await c.ExecAsync("UPDATE tracks SET rating = @rating WHERE id = @trackId", new { trackId, rating = Math.Clamp(rating, 0, 5) }, ct).ConfigureAwait(false);
    }

    public async Task SetFavoriteAsync(long trackId, bool favorite, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        await c.ExecAsync("UPDATE tracks SET favorite = @favorite WHERE id = @trackId", new { trackId, favorite }, ct).ConfigureAwait(false);
    }

    public async Task SetLocalCopyAsync(string sourceUri, string? localPath, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        await c.ExecAsync("UPDATE tracks SET local_copy_path = @localPath WHERE source_uri = @sourceUri", new { sourceUri, localPath }, ct).ConfigureAwait(false);
    }

    public async Task SetArtworkAsync(IEnumerable<long> trackIds, string? artworkHash, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        foreach (var chunk in trackIds.Chunk(500))
            await c.ExecAsync($"UPDATE tracks SET artwork_hash = @artworkHash WHERE id IN ({string.Join(',', chunk)})", new { artworkHash }, ct).ConfigureAwait(false);
    }

    public async Task SetHasLyricsAsync(long trackId, bool hasLyrics, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        await c.ExecAsync("UPDATE tracks SET has_lyrics = @hasLyrics WHERE id = @trackId", new { trackId, hasLyrics }, ct).ConfigureAwait(false);
    }

    public async Task RecordPlayAsync(Track track, long playedMs, bool completed, CancellationToken ct = default)
    {
        var now = DateTimeOffset.UtcNow;
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        long? trackId = track.Id > 0 ? track.Id : null;
        if (trackId is null)
        {
            trackId = await c.ScalarAsync<long?>("SELECT id FROM tracks WHERE source_uri = @SourceUri AND cue_start_ms = @CueStartMs", new { track.SourceUri, track.CueStartMs }, ct).ConfigureAwait(false);
        }
        if (trackId is not null)
            await c.ExecAsync("UPDATE tracks SET play_count = play_count + 1, last_played = @now WHERE id = @trackId", new { now, trackId }, ct).ConfigureAwait(false);
        await c.ExecAsync("INSERT INTO play_history (track_id, source_uri, title, artist, played_at, played_ms, completed) VALUES (@trackId, @SourceUri, @Title, @Artist, @now, @playedMs, @completed)",
            new { trackId, track.SourceUri, Title = track.DisplayTitle, Artist = track.DisplayArtist, now, playedMs, completed }, ct).ConfigureAwait(false);
        track.PlayCount++;
        track.LastPlayed = now;
    }

    public async Task RecordSkipAsync(long trackId, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        await c.ExecAsync("UPDATE tracks SET skip_count = skip_count + 1 WHERE id = @trackId", new { trackId }, ct).ConfigureAwait(false);
    }

    public async Task<IReadOnlyList<PlayHistoryEntry>> GetHistoryAsync(int limit = 200, int offset = 0, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        return await c.QueryAsync($"SELECT id, track_id, source_uri, played_at, played_ms, completed, title, artist FROM play_history ORDER BY played_at DESC LIMIT {Math.Max(1, limit)} OFFSET {Math.Max(0, offset)}",
            r => new PlayHistoryEntry
            {
                Id = r.GetInt64(0), TrackId = r.LongN(1), SourceUri = r.GetString(2), PlayedAt = r.Date(3), PlayedMs = r.Long(4), Completed = r.Bool(5), Title = r.Str(6), Artist = r.Str(7)
            }, null, ct).ConfigureAwait(false);
    }

    public async Task ClearHistoryAsync(CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        await c.ExecAsync("DELETE FROM play_history", null, ct).ConfigureAwait(false);
    }
}
