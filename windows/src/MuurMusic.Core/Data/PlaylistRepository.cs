using System.Text.Json;
using Microsoft.Data.Sqlite;
using MuurMusic.Core.Models;

namespace MuurMusic.Core.Data;

/// <summary>Playlist storage (normal and smart playlists, entries, ordering).</summary>
public interface IPlaylistRepository
{
    Task<IReadOnlyList<Playlist>> GetAllAsync(CancellationToken ct = default);
    Task<Playlist?> GetAsync(long id, CancellationToken ct = default);
    Task<Playlist> CreateAsync(string name, SmartPlaylistDefinition? smart = null, CancellationToken ct = default);
    Task RenameAsync(long id, string name, CancellationToken ct = default);
    Task UpdateSmartAsync(long id, SmartPlaylistDefinition smart, CancellationToken ct = default);
    Task<Playlist> DuplicateAsync(long id, string newName, CancellationToken ct = default);
    Task DeleteAsync(long id, CancellationToken ct = default);
    Task SetSortOrderAsync(IReadOnlyList<long> playlistIdsInOrder, CancellationToken ct = default);
    Task<IReadOnlyList<PlaylistEntry>> GetEntriesAsync(long playlistId, CancellationToken ct = default);
    /// <summary>Adds tracks at <paramref name="position"/> (null = end).</summary>
    Task AddTracksAsync(long playlistId, IEnumerable<Track> tracks, int? position = null, CancellationToken ct = default);
    Task RemoveEntriesAsync(long playlistId, IEnumerable<long> entryIds, CancellationToken ct = default);
    Task MoveEntryAsync(long playlistId, int fromPosition, int toPosition, CancellationToken ct = default);
    Task ReorderAsync(long playlistId, IReadOnlyList<long> entryIdsInOrder, CancellationToken ct = default);
    Task ClearAsync(long playlistId, CancellationToken ct = default);
}

public sealed class PlaylistRepository(LibraryDatabase db) : IPlaylistRepository
{
    private const string Select = """
        SELECT p.id, p.name, p.kind, p.smart_json, p.sort_order, p.created_at, p.updated_at,
               (SELECT count(*) FROM playlist_items i WHERE i.playlist_id = p.id),
               (SELECT coalesce(sum(coalesce(t.duration_ms, i.duration_ms)), 0) FROM playlist_items i LEFT JOIN tracks t ON t.id = i.track_id WHERE i.playlist_id = p.id),
               (SELECT t.artwork_hash FROM playlist_items i JOIN tracks t ON t.id = i.track_id WHERE i.playlist_id = p.id AND t.artwork_hash IS NOT NULL ORDER BY i.position LIMIT 1)
        FROM playlists p
        """;

    private static Playlist Map(SqliteDataReader r)
    {
        var kind = Enum.TryParse<PlaylistKind>(r.GetString(2), out var k) ? k : PlaylistKind.Normal;
        return new Playlist
        {
            Id = r.GetInt64(0), Name = r.GetString(1), Kind = kind,
            Smart = r.IsDBNull(3) ? null : JsonSerializer.Deserialize<SmartPlaylistDefinition>(r.GetString(3)),
            SortOrder = r.Int(4), Created = r.Date(5), Updated = r.Date(6), TrackCount = r.Int(7), DurationMs = r.Long(8), ArtworkHash = r.Str(9)
        };
    }

    public async Task<IReadOnlyList<Playlist>> GetAllAsync(CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        return await c.QueryAsync($"{Select} ORDER BY p.sort_order, p.name COLLATE NOCASE", Map, null, ct).ConfigureAwait(false);
    }

    public async Task<Playlist?> GetAsync(long id, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        return (await c.QueryAsync($"{Select} WHERE p.id = @id", Map, new { id }, ct).ConfigureAwait(false)).FirstOrDefault();
    }

    public async Task<Playlist> CreateAsync(string name, SmartPlaylistDefinition? smart = null, CancellationToken ct = default)
    {
        var now = DateTimeOffset.UtcNow;
        if (smart is not null) smart.Name = name;
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        var order = await c.ScalarAsync<int>("SELECT coalesce(max(sort_order), 0) + 1 FROM playlists", null, ct).ConfigureAwait(false);
        var id = await c.ScalarAsync<long>("INSERT INTO playlists (name, kind, smart_json, sort_order, created_at, updated_at) VALUES (@name, @kind, @smart, @order, @now, @now) RETURNING id",
            new { name, kind = smart is null ? PlaylistKind.Normal : PlaylistKind.Smart, smart = smart is null ? null : JsonSerializer.Serialize(smart), order, now }, ct).ConfigureAwait(false);
        return (await GetAsync(id, ct).ConfigureAwait(false))!;
    }

    public async Task RenameAsync(long id, string name, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        await c.ExecAsync("UPDATE playlists SET name = @name, updated_at = @now, smart_json = CASE WHEN smart_json IS NULL THEN NULL ELSE json_set(smart_json, '$.name', @name) END WHERE id = @id",
            new { id, name, now = DateTimeOffset.UtcNow }, ct).ConfigureAwait(false);
    }

    public async Task UpdateSmartAsync(long id, SmartPlaylistDefinition smart, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        await c.ExecAsync("UPDATE playlists SET kind = 'Smart', smart_json = @json, name = @name, updated_at = @now WHERE id = @id",
            new { id, json = JsonSerializer.Serialize(smart), name = smart.Name, now = DateTimeOffset.UtcNow }, ct).ConfigureAwait(false);
    }

    public async Task<Playlist> DuplicateAsync(long id, string newName, CancellationToken ct = default)
    {
        var source = await GetAsync(id, ct).ConfigureAwait(false) ?? throw new KeyNotFoundException($"Playlist {id} not found");
        SmartPlaylistDefinition? smart = source.Smart is null ? null : JsonSerializer.Deserialize<SmartPlaylistDefinition>(JsonSerializer.Serialize(source.Smart));
        var copy = await CreateAsync(newName, smart, ct).ConfigureAwait(false);
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        await c.ExecAsync("INSERT INTO playlist_items (playlist_id, position, track_id, source_uri, cue_start_ms, title, artist, duration_ms) " +
                          "SELECT @copy, position, track_id, source_uri, cue_start_ms, title, artist, duration_ms FROM playlist_items WHERE playlist_id = @id ORDER BY position",
            new { copy = copy.Id, id }, ct).ConfigureAwait(false);
        return (await GetAsync(copy.Id, ct).ConfigureAwait(false))!;
    }

    public async Task DeleteAsync(long id, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        await c.ExecAsync("DELETE FROM playlists WHERE id = @id", new { id }, ct).ConfigureAwait(false);
    }

    public async Task SetSortOrderAsync(IReadOnlyList<long> playlistIdsInOrder, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        await using var tx = (SqliteTransaction)await c.BeginTransactionAsync(ct).ConfigureAwait(false);
        for (var i = 0; i < playlistIdsInOrder.Count; i++)
            await c.ExecAsync("UPDATE playlists SET sort_order = @i WHERE id = @id", new { i, id = playlistIdsInOrder[i] }, ct, tx).ConfigureAwait(false);
        await tx.CommitAsync(ct).ConfigureAwait(false);
    }

    public async Task<IReadOnlyList<PlaylistEntry>> GetEntriesAsync(long playlistId, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        // Re-link entries whose track was (re-)added to the library under the same URI.
        await c.ExecAsync("UPDATE playlist_items SET track_id = (SELECT t.id FROM tracks t WHERE t.source_uri = playlist_items.source_uri AND t.cue_start_ms = playlist_items.cue_start_ms) " +
                          "WHERE playlist_id = @playlistId AND track_id IS NULL", new { playlistId }, ct).ConfigureAwait(false);
        var sql = $"SELECT i.id, i.playlist_id, i.position, i.track_id, i.source_uri, i.cue_start_ms, i.title, i.artist, i.duration_ms, {TrackRepository.Columns} " +
                  "FROM playlist_items i LEFT JOIN tracks t ON t.id = i.track_id WHERE i.playlist_id = @playlistId ORDER BY i.position";
        return await c.QueryAsync(sql, r => new PlaylistEntry
        {
            Id = r.GetInt64(0), PlaylistId = r.GetInt64(1), Position = r.Int(2), TrackId = r.LongN(3), SourceUri = r.GetString(4),
            CueStartMs = r.Long(5), Title = r.Str(6), Artist = r.Str(7), DurationMs = r.Long(8),
            Track = r.IsDBNull(9) ? null : TrackRepository.Map(r, 9)
        }, new { playlistId }, ct).ConfigureAwait(false);
    }

    public async Task AddTracksAsync(long playlistId, IEnumerable<Track> tracks, int? position = null, CancellationToken ct = default)
    {
        var list = tracks.ToList();
        if (list.Count == 0) return;
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        await using var tx = (SqliteTransaction)await c.BeginTransactionAsync(ct).ConfigureAwait(false);
        var count = await c.ScalarAsync<int>("SELECT count(*) FROM playlist_items WHERE playlist_id = @playlistId", new { playlistId }, ct, tx).ConfigureAwait(false);
        var insertAt = Math.Clamp(position ?? count, 0, count);
        await c.ExecAsync("UPDATE playlist_items SET position = position + @n WHERE playlist_id = @playlistId AND position >= @insertAt",
            new { n = list.Count, playlistId, insertAt }, ct, tx).ConfigureAwait(false);
        for (var i = 0; i < list.Count; i++)
        {
            var t = list[i];
            var trackId = t.Id > 0 ? t.Id : await c.ScalarAsync<long?>("SELECT id FROM tracks WHERE source_uri = @SourceUri AND cue_start_ms = @CueStartMs", new { t.SourceUri, t.CueStartMs }, ct, tx).ConfigureAwait(false);
            await c.ExecAsync("INSERT INTO playlist_items (playlist_id, position, track_id, source_uri, cue_start_ms, title, artist, duration_ms) VALUES (@playlistId, @pos, @trackId, @SourceUri, @CueStartMs, @Title, @Artist, @DurationMs)",
                new { playlistId, pos = insertAt + i, trackId, t.SourceUri, t.CueStartMs, Title = t.DisplayTitle, Artist = t.DisplayArtist, t.DurationMs }, ct, tx).ConfigureAwait(false);
        }
        await c.ExecAsync("UPDATE playlists SET updated_at = @now WHERE id = @playlistId", new { now = DateTimeOffset.UtcNow, playlistId }, ct, tx).ConfigureAwait(false);
        await tx.CommitAsync(ct).ConfigureAwait(false);
    }

    public async Task RemoveEntriesAsync(long playlistId, IEnumerable<long> entryIds, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        await using var tx = (SqliteTransaction)await c.BeginTransactionAsync(ct).ConfigureAwait(false);
        foreach (var chunk in entryIds.Chunk(500))
            await c.ExecAsync($"DELETE FROM playlist_items WHERE playlist_id = @playlistId AND id IN ({string.Join(',', chunk)})", new { playlistId }, ct, tx).ConfigureAwait(false);
        await Renumber(c, tx, playlistId, ct).ConfigureAwait(false);
        await tx.CommitAsync(ct).ConfigureAwait(false);
    }

    public async Task MoveEntryAsync(long playlistId, int fromPosition, int toPosition, CancellationToken ct = default)
    {
        List<long> ids;
        await using (var c = await db.OpenAsync(ct).ConfigureAwait(false))
            ids = await c.QueryAsync("SELECT id FROM playlist_items WHERE playlist_id = @playlistId ORDER BY position, id", r => r.GetInt64(0), new { playlistId }, ct).ConfigureAwait(false);
        if (fromPosition < 0 || fromPosition >= ids.Count || toPosition < 0 || toPosition >= ids.Count) return;
        var id = ids[fromPosition];
        ids.RemoveAt(fromPosition);
        ids.Insert(toPosition, id);
        await ReorderAsync(playlistId, ids, ct).ConfigureAwait(false);
    }

    public async Task ReorderAsync(long playlistId, IReadOnlyList<long> entryIdsInOrder, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        await using var tx = (SqliteTransaction)await c.BeginTransactionAsync(ct).ConfigureAwait(false);
        for (var i = 0; i < entryIdsInOrder.Count; i++)
            await c.ExecAsync("UPDATE playlist_items SET position = @i WHERE id = @id AND playlist_id = @playlistId", new { i, id = entryIdsInOrder[i], playlistId }, ct, tx).ConfigureAwait(false);
        await c.ExecAsync("UPDATE playlists SET updated_at = @now WHERE id = @playlistId", new { now = DateTimeOffset.UtcNow, playlistId }, ct, tx).ConfigureAwait(false);
        await tx.CommitAsync(ct).ConfigureAwait(false);
    }

    public async Task ClearAsync(long playlistId, CancellationToken ct = default)
    {
        await using var c = await db.OpenAsync(ct).ConfigureAwait(false);
        await c.ExecAsync("DELETE FROM playlist_items WHERE playlist_id = @playlistId", new { playlistId }, ct).ConfigureAwait(false);
    }

    private static async Task Renumber(SqliteConnection c, SqliteTransaction tx, long playlistId, CancellationToken ct)
    {
        var ids = await c.QueryAsync("SELECT id FROM playlist_items WHERE playlist_id = @playlistId ORDER BY position, id", r => r.GetInt64(0), new { playlistId }, ct, tx).ConfigureAwait(false);
        for (var i = 0; i < ids.Count; i++)
            await c.ExecAsync("UPDATE playlist_items SET position = @i WHERE id = @id", new { i, id = ids[i] }, ct, tx).ConfigureAwait(false);
    }
}
