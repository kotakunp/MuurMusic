using System.Text.Json;
using Microsoft.Data.Sqlite;
using MuurMusic.Core.Models;

namespace MuurMusic.Core.Data;

public interface IBookmarkRepository
{
    Task<Bookmark> AddAsync(Track track, long positionMs, string? note = null, CancellationToken ct = default);
    Task<IReadOnlyList<Bookmark>> GetAllAsync(CancellationToken ct = default);
    Task<IReadOnlyList<Bookmark>> GetForTrackAsync(Track track, CancellationToken ct = default);
    Task UpdateNoteAsync(long id, string? note, CancellationToken ct = default);
    Task DeleteAsync(long id, CancellationToken ct = default);
}

public sealed class BookmarkRepository(LibraryDatabase db) : IBookmarkRepository
{
    private const string Select = "SELECT id, track_id, source_uri, cue_start_ms, position_ms, note, created_at, title, artist FROM bookmarks";

    private static Bookmark Map(SqliteDataReader r) => new()
    {
        Id = r.GetInt64(0), TrackId = r.LongN(1), SourceUri = r.GetString(2), CueStartMs = r.Long(3), PositionMs = r.Long(4),
        Note = r.Str(5), Created = r.Date(6), TrackTitle = r.Str(7), TrackArtist = r.Str(8)
    };

    public async Task<Bookmark> AddAsync(Track track, long positionMs, string? note = null, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        var id = await c.ScalarAsync<long>("INSERT INTO bookmarks (track_id, source_uri, cue_start_ms, position_ms, note, title, artist, created_at) VALUES (@trackId, @SourceUri, @CueStartMs, @positionMs, @note, @title, @artist, @now) RETURNING id",
            new { trackId = track.Id > 0 ? track.Id : (long?)null, track.SourceUri, track.CueStartMs, positionMs, note, title = track.DisplayTitle, artist = track.DisplayArtist, now = DateTimeOffset.UtcNow }, ct).ConfigureAwait(false);
        return (await c.QueryAsync($"{Select} WHERE id = @id", Map, new { id }, ct).ConfigureAwait(false))[0];
    }

    public async Task<IReadOnlyList<Bookmark>> GetAllAsync(CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        return await c.QueryAsync($"{Select} ORDER BY created_at DESC", Map, null, ct).ConfigureAwait(false);
    }

    public async Task<IReadOnlyList<Bookmark>> GetForTrackAsync(Track track, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        return await c.QueryAsync($"{Select} WHERE source_uri = @SourceUri AND cue_start_ms = @CueStartMs ORDER BY position_ms", Map, new { track.SourceUri, track.CueStartMs }, ct).ConfigureAwait(false);
    }

    public async Task UpdateNoteAsync(long id, string? note, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        await c.ExecAsync("UPDATE bookmarks SET note = @note WHERE id = @id", new { id, note }, ct).ConfigureAwait(false);
    }

    public async Task DeleteAsync(long id, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        await c.ExecAsync("DELETE FROM bookmarks WHERE id = @id", new { id }, ct).ConfigureAwait(false);
    }
}

public interface ISourceRepository
{
    Task<IReadOnlyList<SourceConfig>> GetAllAsync(CancellationToken ct = default);
    Task<SourceConfig?> GetAsync(Guid id, CancellationToken ct = default);
    Task SaveAsync(SourceConfig config, CancellationToken ct = default);
    Task DeleteAsync(Guid id, CancellationToken ct = default);
}

public sealed class SourceRepository(LibraryDatabase db) : ISourceRepository
{
    private static SourceConfig Map(SqliteDataReader r) => new()
    {
        Id = Guid.Parse(r.GetString(0)),
        Kind = Enum.Parse<SourceKind>(r.GetString(1)),
        Name = r.GetString(2),
        Settings = new Dictionary<string, string>(JsonSerializer.Deserialize<Dictionary<string, string>>(r.GetString(3)) ?? new(), StringComparer.OrdinalIgnoreCase),
        Enabled = r.Bool(4),
        SortOrder = r.Int(5),
        Created = r.Date(6)
    };

    public async Task<IReadOnlyList<SourceConfig>> GetAllAsync(CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        return await c.QueryAsync("SELECT id, kind, name, config_json, enabled, sort_order, created_at FROM sources ORDER BY sort_order, name COLLATE NOCASE", Map, null, ct).ConfigureAwait(false);
    }

    public async Task<SourceConfig?> GetAsync(Guid id, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        return (await c.QueryAsync("SELECT id, kind, name, config_json, enabled, sort_order, created_at FROM sources WHERE id = @id", Map, new { id }, ct).ConfigureAwait(false)).FirstOrDefault();
    }

    public async Task SaveAsync(SourceConfig config, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        await c.ExecAsync("""
            INSERT INTO sources (id, kind, name, config_json, enabled, sort_order, created_at) VALUES (@Id, @Kind, @Name, @json, @Enabled, @SortOrder, @Created)
            ON CONFLICT(id) DO UPDATE SET kind = excluded.kind, name = excluded.name, config_json = excluded.config_json, enabled = excluded.enabled, sort_order = excluded.sort_order
            """, new { config.Id, config.Kind, config.Name, json = JsonSerializer.Serialize(config.Settings), config.Enabled, config.SortOrder, config.Created }, ct).ConfigureAwait(false);
    }

    public async Task DeleteAsync(Guid id, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        await c.ExecAsync("DELETE FROM sources WHERE id = @id", new { id }, ct).ConfigureAwait(false);
    }
}

public interface IDownloadRepository
{
    Task<IReadOnlyList<DownloadItem>> GetAllAsync(CancellationToken ct = default);
    Task SaveAsync(DownloadItem item, CancellationToken ct = default);
    Task DeleteAsync(Guid id, CancellationToken ct = default);
    Task DeleteCompletedAsync(CancellationToken ct = default);
}

public sealed class DownloadRepository(LibraryDatabase db) : IDownloadRepository
{
    public async Task<IReadOnlyList<DownloadItem>> GetAllAsync(CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        return await c.QueryAsync("SELECT id, source_uri, track_id, title, artist, destination, total_bytes, downloaded_bytes, state, kind, error, attempts, created_at, updated_at FROM downloads ORDER BY created_at",
            r => new DownloadItem
            {
                Id = Guid.Parse(r.GetString(0)), SourceUri = r.GetString(1), TrackId = r.LongN(2), Title = r.GetString(3), Artist = r.Str(4), DestinationPath = r.GetString(5),
                TotalBytes = r.Long(6), DownloadedBytes = r.Long(7), State = Enum.Parse<DownloadState>(r.GetString(8)), Kind = Enum.Parse<DownloadKind>(r.GetString(9)),
                Error = r.Str(10), Attempts = r.Int(11), Created = r.Date(12), Updated = r.Date(13)
            }, null, ct).ConfigureAwait(false);
    }

    public async Task SaveAsync(DownloadItem i, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        await c.ExecAsync("""
            INSERT INTO downloads (id, source_uri, track_id, title, artist, destination, total_bytes, downloaded_bytes, state, kind, error, attempts, created_at, updated_at)
            VALUES (@Id, @SourceUri, @TrackId, @Title, @Artist, @DestinationPath, @TotalBytes, @DownloadedBytes, @State, @Kind, @Error, @Attempts, @Created, @Updated)
            ON CONFLICT(id) DO UPDATE SET destination = excluded.destination, total_bytes = excluded.total_bytes, downloaded_bytes = excluded.downloaded_bytes,
                state = excluded.state, error = excluded.error, attempts = excluded.attempts, updated_at = excluded.updated_at
            """, new { i.Id, i.SourceUri, i.TrackId, i.Title, i.Artist, i.DestinationPath, i.TotalBytes, i.DownloadedBytes, i.State, i.Kind, i.Error, i.Attempts, i.Created, i.Updated }, ct).ConfigureAwait(false);
    }

    public async Task DeleteAsync(Guid id, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        await c.ExecAsync("DELETE FROM downloads WHERE id = @id", new { id }, ct).ConfigureAwait(false);
    }

    public async Task DeleteCompletedAsync(CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        await c.ExecAsync("DELETE FROM downloads WHERE state IN ('Completed', 'Canceled')", null, ct).ConfigureAwait(false);
    }
}

/// <summary>Custom EQ presets and named DSP chains.</summary>
public interface IPresetRepository
{
    Task<IReadOnlyList<EqPreset>> GetEqPresetsAsync(CancellationToken ct = default);
    Task SaveEqPresetAsync(EqPreset preset, CancellationToken ct = default);
    Task RenameEqPresetAsync(string oldName, string newName, CancellationToken ct = default);
    Task DeleteEqPresetAsync(string name, CancellationToken ct = default);
    Task<IReadOnlyList<(string Name, string Json)>> GetDspChainsAsync(CancellationToken ct = default);
    Task SaveDspChainAsync(string name, string json, CancellationToken ct = default);
    Task DeleteDspChainAsync(string name, CancellationToken ct = default);
}

public sealed class PresetRepository(LibraryDatabase db) : IPresetRepository
{
    public async Task<IReadOnlyList<EqPreset>> GetEqPresetsAsync(CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        return await c.QueryAsync("SELECT name, preamp_db, bands_json FROM eq_presets ORDER BY name COLLATE NOCASE",
            r => new EqPreset { Name = r.GetString(0), PreampDb = r.GetDouble(1), Bands = JsonSerializer.Deserialize<List<EqBand>>(r.GetString(2)) ?? new() }.Normalize(), null, ct).ConfigureAwait(false);
    }

    public async Task SaveEqPresetAsync(EqPreset preset, CancellationToken ct = default)
    {
        var p = preset.Normalize();
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        await c.ExecAsync("INSERT INTO eq_presets (name, preamp_db, bands_json, updated_at) VALUES (@name, @preamp, @bands, @now) ON CONFLICT(name) DO UPDATE SET preamp_db = excluded.preamp_db, bands_json = excluded.bands_json, updated_at = excluded.updated_at",
            new { name = p.Name, preamp = p.PreampDb, bands = JsonSerializer.Serialize(p.Bands), now = DateTimeOffset.UtcNow }, ct).ConfigureAwait(false);
    }

    public async Task RenameEqPresetAsync(string oldName, string newName, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        await c.ExecAsync("UPDATE eq_presets SET name = @newName, updated_at = @now WHERE name = @oldName", new { oldName, newName, now = DateTimeOffset.UtcNow }, ct).ConfigureAwait(false);
    }

    public async Task DeleteEqPresetAsync(string name, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        await c.ExecAsync("DELETE FROM eq_presets WHERE name = @name", new { name }, ct).ConfigureAwait(false);
    }

    public async Task<IReadOnlyList<(string Name, string Json)>> GetDspChainsAsync(CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        return await c.QueryAsync("SELECT name, chain_json FROM dsp_chains ORDER BY name COLLATE NOCASE", r => (r.GetString(0), r.GetString(1)), null, ct).ConfigureAwait(false);
    }

    public async Task SaveDspChainAsync(string name, string json, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        await c.ExecAsync("INSERT INTO dsp_chains (name, chain_json, updated_at) VALUES (@name, @json, @now) ON CONFLICT(name) DO UPDATE SET chain_json = excluded.chain_json, updated_at = excluded.updated_at",
            new { name, json, now = DateTimeOffset.UtcNow }, ct).ConfigureAwait(false);
    }

    public async Task DeleteDspChainAsync(string name, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        await c.ExecAsync("DELETE FROM dsp_chains WHERE name = @name", new { name }, ct).ConfigureAwait(false);
    }
}

/// <summary>Index of the automatic audio cache (LRU by last access).</summary>
public interface IAudioCacheRepository
{
    Task<(string Path, long Size)?> GetAsync(string sourceUri, CancellationToken ct = default);
    Task UpsertAsync(string sourceUri, string path, long size, CancellationToken ct = default);
    Task TouchAsync(string sourceUri, CancellationToken ct = default);
    Task DeleteAsync(string sourceUri, CancellationToken ct = default);
    Task<long> GetTotalSizeAsync(CancellationToken ct = default);
    Task<IReadOnlyList<(string SourceUri, string Path, long Size)>> GetOldestAsync(int count, CancellationToken ct = default);
    Task ClearAsync(CancellationToken ct = default);
}

public sealed class AudioCacheRepository(LibraryDatabase db) : IAudioCacheRepository
{
    public async Task<(string Path, long Size)?> GetAsync(string sourceUri, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        var rows = await c.QueryAsync("SELECT path, size FROM audio_cache WHERE source_uri = @sourceUri", r => (r.GetString(0), r.GetInt64(1)), new { sourceUri }, ct).ConfigureAwait(false);
        return rows.Count == 0 ? null : rows[0];
    }

    public async Task UpsertAsync(string sourceUri, string path, long size, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        await c.ExecAsync("INSERT INTO audio_cache (source_uri, path, size, last_access) VALUES (@sourceUri, @path, @size, @now) ON CONFLICT(source_uri) DO UPDATE SET path = excluded.path, size = excluded.size, last_access = excluded.last_access",
            new { sourceUri, path, size, now = DateTimeOffset.UtcNow }, ct).ConfigureAwait(false);
    }

    public async Task TouchAsync(string sourceUri, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        await c.ExecAsync("UPDATE audio_cache SET last_access = @now WHERE source_uri = @sourceUri", new { sourceUri, now = DateTimeOffset.UtcNow }, ct).ConfigureAwait(false);
    }

    public async Task DeleteAsync(string sourceUri, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        await c.ExecAsync("DELETE FROM audio_cache WHERE source_uri = @sourceUri", new { sourceUri }, ct).ConfigureAwait(false);
    }

    public async Task<long> GetTotalSizeAsync(CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        return await c.ScalarAsync<long>("SELECT coalesce(sum(size), 0) FROM audio_cache", null, ct).ConfigureAwait(false);
    }

    public async Task<IReadOnlyList<(string SourceUri, string Path, long Size)>> GetOldestAsync(int count, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        return await c.QueryAsync($"SELECT source_uri, path, size FROM audio_cache ORDER BY last_access LIMIT {Math.Max(1, count)}", r => (r.GetString(0), r.GetString(1), r.GetInt64(2)), null, ct).ConfigureAwait(false);
    }

    public async Task ClearAsync(CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        await c.ExecAsync("DELETE FROM audio_cache", null, ct).ConfigureAwait(false);
    }
}

/// <summary>Small key/value store in the <c>settings</c> table for device-local state (scan timestamps etc.).</summary>
public interface IKeyValueStore
{
    Task<string?> GetAsync(string key, CancellationToken ct = default);
    Task SetAsync(string key, string? value, CancellationToken ct = default);
}

public sealed class KeyValueStore(LibraryDatabase db) : IKeyValueStore
{
    public async Task<string?> GetAsync(string key, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        return await c.ScalarAsync<string>("SELECT value FROM settings WHERE key = @key", new { key }, ct).ConfigureAwait(false);
    }

    public async Task SetAsync(string key, string? value, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        await c.ExecAsync("INSERT INTO settings (key, value) VALUES (@key, @value) ON CONFLICT(key) DO UPDATE SET value = excluded.value", new { key, value }, ct).ConfigureAwait(false);
    }
}
