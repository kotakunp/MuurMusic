using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Extensions.Logging;
using MuurMusic.Core.Data;
using MuurMusic.Core.Infrastructure;
using MuurMusic.Core.Models;

namespace MuurMusic.Core.Playback;

/// <summary>Persisted play queue (queue.json).</summary>
public sealed class QueueSnapshot
{
    public int Version { get; set; } = 1;
    public List<QueueSnapshotEntry> Entries { get; set; } = new();
    public List<int> Order { get; set; } = new();
    public int OrderPosition { get; set; } = -1;
    public bool Shuffle { get; set; }
    public RepeatMode Repeat { get; set; }
    /// <summary>Position inside the current track (relative to its CUE start).</summary>
    public long PositionMs { get; set; }
    public DateTimeOffset Saved { get; set; } = DateTimeOffset.UtcNow;
}

public sealed class QueueSnapshotEntry
{
    public Guid EntryId { get; set; }
    public Track Track { get; set; } = new();
}

/// <summary>Saves and restores the play queue between sessions.</summary>
public interface IQueueStore
{
    QueueSnapshot Capture(PlayQueue queue, long positionMs);
    Task SaveAsync(QueueSnapshot snapshot, CancellationToken ct = default);
    /// <summary>Loads queue.json and refreshes library tracks from the database (tags/ratings may have changed). Null when there is nothing to restore.</summary>
    Task<QueueSnapshot?> LoadAsync(CancellationToken ct = default);
    void Apply(PlayQueue queue, QueueSnapshot snapshot);
    Task ClearAsync(CancellationToken ct = default);
}

public sealed class QueueStore(AppPaths paths, ITrackRepository tracks, ILogger<QueueStore> log) : IQueueStore
{
    private static readonly JsonSerializerOptions Options = new()
    {
        IgnoreReadOnlyProperties = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Converters = { new JsonStringEnumConverter() }
    };

    private readonly SemaphoreSlim _lock = new(1, 1);

    public QueueSnapshot Capture(PlayQueue queue, long positionMs) => new()
    {
        Entries = queue.Items.Select(e => new QueueSnapshotEntry { EntryId = e.EntryId, Track = e.Track.Clone() }).ToList(),
        Order = queue.Order.ToList(),
        OrderPosition = queue.OrderPosition,
        Shuffle = queue.Shuffle,
        Repeat = queue.Repeat,
        PositionMs = Math.Max(0, positionMs)
    };

    public async Task SaveAsync(QueueSnapshot snapshot, CancellationToken ct = default)
    {
        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            snapshot.Saved = DateTimeOffset.UtcNow;
            var tmp = paths.QueuePath + ".tmp";
            await using (var fs = new FileStream(tmp, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16, FileOptions.Asynchronous))
                await JsonSerializer.SerializeAsync(fs, snapshot, Options, ct).ConfigureAwait(false);
            File.Move(tmp, paths.QueuePath, overwrite: true);
        }
        finally { _lock.Release(); }
    }

    public async Task<QueueSnapshot?> LoadAsync(CancellationToken ct = default)
    {
        if (!File.Exists(paths.QueuePath)) return null;
        QueueSnapshot? snapshot;
        try
        {
            await using var fs = new FileStream(paths.QueuePath, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16, FileOptions.Asynchronous);
            snapshot = await JsonSerializer.DeserializeAsync<QueueSnapshot>(fs, Options, ct).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is JsonException or IOException)
        {
            log.LogWarning(ex, "queue.json is unreadable; starting with an empty queue");
            return null;
        }
        if (snapshot is null || snapshot.Entries.Count == 0) return null;
        var ids = snapshot.Entries.Where(e => e.Track.Id > 0).Select(e => e.Track.Id).Distinct().ToList();
        if (ids.Count > 0)
        {
            var fresh = (await tracks.GetByIdsAsync(ids, ct).ConfigureAwait(false)).ToDictionary(t => t.Id);
            foreach (var e in snapshot.Entries)
            {
                if (e.Track.Id <= 0) continue;
                if (fresh.TryGetValue(e.Track.Id, out var t)) e.Track = t;
                else e.Track.Id = 0; // Removed from the library since: keep the snapshot copy as a plain URI track.
            }
        }
        return snapshot;
    }

    public void Apply(PlayQueue queue, QueueSnapshot snapshot) =>
        queue.Restore(snapshot.Entries.Select(e => new QueueEntry(e.EntryId == Guid.Empty ? Guid.NewGuid() : e.EntryId, e.Track)),
            snapshot.Order, snapshot.OrderPosition, snapshot.Shuffle, snapshot.Repeat);

    public async Task ClearAsync(CancellationToken ct = default)
    {
        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try { if (File.Exists(paths.QueuePath)) File.Delete(paths.QueuePath); }
        finally { _lock.Release(); }
    }
}
