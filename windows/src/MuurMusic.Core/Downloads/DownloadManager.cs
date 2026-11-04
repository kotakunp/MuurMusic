using System.Collections.Concurrent;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Extensions.Logging;
using MuurMusic.Core.Data;
using MuurMusic.Core.Infrastructure;
using MuurMusic.Core.Models;
using MuurMusic.Core.Settings;
using MuurMusic.Core.Sources;

namespace MuurMusic.Core.Downloads;

/// <summary>
/// Download manager: offline copies, plain downloads and the automatic LRU audio cache. Downloads run concurrently
/// (<see cref="AppSettings.DownloadConcurrency"/>), resume with HTTP Range / offset reads after pauses, failures and
/// restarts, retry transient errors with exponential back-off and are persisted in the database.
/// </summary>
public interface IDownloadManager : IAsyncDisposable
{
    /// <summary>Loads persisted downloads and restarts unfinished ones. Call once at startup (after the source manager).</summary>
    Task InitializeAsync(CancellationToken ct = default);
    /// <summary>Snapshot of all user-visible items (offline and export downloads; cache fills are excluded).</summary>
    IReadOnlyList<DownloadItem> Items { get; }
    /// <summary>Raised on a background thread with a snapshot whenever an item's progress or state changes (throttled to ~4/s per item).</summary>
    event EventHandler<DownloadItem>? ItemChanged;
    /// <summary>Raised on a background thread when items are added or removed.</summary>
    event EventHandler? ItemsChanged;
    /// <summary>Raised after an offline copy finished (track source URI, local path) or was removed (path null).</summary>
    event EventHandler<(string SourceUri, string? LocalPath)>? OfflineCopyChanged;

    /// <summary>Queues offline copies (kept until removed). Tracks that already have a local file are skipped.</summary>
    Task<IReadOnlyList<DownloadItem>> MakeAvailableOfflineAsync(IEnumerable<Track> tracks, CancellationToken ct = default);
    /// <summary>Deletes the offline copy of a track and cancels a pending offline download for it.</summary>
    Task RemoveOfflineCopyAsync(Track track, CancellationToken ct = default);
    /// <summary>Downloads tracks as files into <paramref name="folder"/> (default: <see cref="AppSettings.DownloadFolder"/> or Music\MuurMusic).</summary>
    Task<IReadOnlyList<DownloadItem>> DownloadToFolderAsync(IEnumerable<Track> tracks, string? folder = null, CancellationToken ct = default);
    /// <summary>Downloads any source URI (e.g. a non-audio file from the browser) into a folder.</summary>
    Task<DownloadItem> DownloadUriAsync(string sourceUri, string? fileName = null, string? folder = null, CancellationToken ct = default);
    /// <summary>Fills the automatic audio cache with a remote track in the background (no-op when cached, local or the cache is disabled).</summary>
    Task CacheTrackAsync(Track track, CancellationToken ct = default);

    void Pause(Guid id);
    void Resume(Guid id);
    /// <summary>Restarts a failed or canceled item (keeps the partial data).</summary>
    void Retry(Guid id);
    Task CancelAsync(Guid id);
    /// <summary>Removes an item from the list; <paramref name="deleteFile"/> also deletes a completed file.</summary>
    Task RemoveAsync(Guid id, bool deleteFile = false);
    void PauseAll();
    void ResumeAll();
    /// <summary>Removes completed and canceled items from the list (files are kept).</summary>
    Task ClearFinishedAsync(CancellationToken ct = default);

    Task<long> GetCacheSizeAsync(CancellationToken ct = default);
    Task ClearCacheAsync(CancellationToken ct = default);
    /// <summary>Evicts least-recently-used cache files until the cache fits <see cref="AppSettings.AudioCacheMaxBytes"/>.</summary>
    Task EnforceCacheLimitAsync(CancellationToken ct = default);
    /// <summary>Total size of offline copies on disk.</summary>
    long GetOfflineSize();
}

public sealed class DownloadManager : IDownloadManager
{
    private const int MaxAttempts = 6;
    private static readonly TimeSpan ReadStallTimeout = TimeSpan.FromSeconds(60);

    private readonly ISourceManager _sources;
    private readonly IDownloadRepository _repo;
    private readonly ITrackRepository _tracks;
    private readonly IAudioCacheRepository _cache;
    private readonly ISettingsService _settings;
    private readonly AppPaths _paths;
    private readonly IHttpClientFactory _httpFactory;
    private readonly ILogger<DownloadManager> _log;

    private readonly object _gate = new();
    private readonly List<Entry> _entries = new();
    private readonly ConcurrentDictionary<string, byte> _cacheInFlight = new(StringComparer.OrdinalIgnoreCase);
    private readonly SemaphoreSlim _cacheLock = new(1, 1);
    private readonly CancellationTokenSource _shutdown = new();
    private bool _initialized;

    public DownloadManager(ISourceManager sources, IDownloadRepository repo, ITrackRepository tracks, IAudioCacheRepository cache,
        ISettingsService settings, AppPaths paths, IHttpClientFactory httpFactory, ILogger<DownloadManager> log)
    {
        _sources = sources;
        _repo = repo;
        _tracks = tracks;
        _cache = cache;
        _settings = settings;
        _paths = paths;
        _httpFactory = httpFactory;
        _log = log;
        _settings.Changed += (_, e) =>
        {
            if (e.New.DownloadConcurrency != e.Old.DownloadConcurrency || e.New.OfflineMode != e.Old.OfflineMode) Pump();
            if (e.New.AudioCacheMaxBytes < e.Old.AudioCacheMaxBytes || (!e.New.AudioCacheEnabled && e.Old.AudioCacheEnabled))
                _ = Task.Run(async () =>
                {
                    try
                    {
                        if (!e.New.AudioCacheEnabled) await ClearCacheAsync().ConfigureAwait(false);
                        else await EnforceCacheLimitAsync().ConfigureAwait(false);
                    }
                    catch (Exception ex) { _log.LogWarning(ex, "Cache maintenance failed"); }
                });
        };
    }

    private sealed class Entry(DownloadItem item, Track? track)
    {
        public DownloadItem Item { get; } = item;
        public Track? Track { get; set; } = track;
        public CancellationTokenSource? Cts { get; set; }
        public Task? Worker { get; set; }
        public long LastEventTicks { get; set; }
        public long LastPersistTicks { get; set; }
        public DateTimeOffset? NotBefore { get; set; }
        public bool Running => Worker is { IsCompleted: false };
    }

    public event EventHandler<DownloadItem>? ItemChanged;
    public event EventHandler? ItemsChanged;
    public event EventHandler<(string SourceUri, string? LocalPath)>? OfflineCopyChanged;

    public IReadOnlyList<DownloadItem> Items
    {
        get
        {
            lock (_gate) return _entries.Where(e => e.Item.Kind != DownloadKind.Cache).Select(e => e.Item.Clone()).ToList();
        }
    }

    public async Task InitializeAsync(CancellationToken ct = default)
    {
        if (_initialized) return;
        _initialized = true;
        var items = await _repo.GetAllAsync(ct).ConfigureAwait(false);
        lock (_gate)
        {
            foreach (var item in items)
            {
                if (item.Kind == DownloadKind.Cache) continue;
                if (item.State == DownloadState.Downloading) item.State = DownloadState.Queued;
                var part = PartPath(item);
                item.DownloadedBytes = item.State == DownloadState.Completed ? item.DownloadedBytes : (File.Exists(part) ? new FileInfo(part).Length : 0);
                _entries.Add(new Entry(item, null));
            }
        }
        // Offline copies whose files vanished are reset so playback falls back to the source.
        foreach (var item in items.Where(i => i.Kind == DownloadKind.Offline && i.State == DownloadState.Completed && !File.Exists(i.DestinationPath)))
        {
            await _tracks.SetLocalCopyAsync(item.SourceUri, null, ct).ConfigureAwait(false);
            item.State = DownloadState.Failed;
            item.Error = "The offline file was deleted.";
            await _repo.SaveAsync(item, ct).ConfigureAwait(false);
        }
        CleanOrphanPartials();
        ItemsChanged?.Invoke(this, EventArgs.Empty);
        Pump();
    }

    private void CleanOrphanPartials()
    {
        HashSet<string> keep;
        lock (_gate) keep = _entries.Select(e => PartPath(e.Item)).ToHashSet(StringComparer.OrdinalIgnoreCase);
        try
        {
            foreach (var f in Directory.EnumerateFiles(_paths.DownloadsTempDirectory, "*.part"))
                if (!keep.Contains(f) && File.GetLastWriteTimeUtc(f) < DateTime.UtcNow.AddHours(-1)) TryDelete(f);
        }
        catch (IOException ex) { _log.LogDebug(ex, "Partial cleanup failed"); }
    }

    public async Task<IReadOnlyList<DownloadItem>> MakeAvailableOfflineAsync(IEnumerable<Track> tracks, CancellationToken ct = default)
    {
        var added = new List<DownloadItem>();
        foreach (var t in tracks.DistinctBy(t => t.SourceUri, StringComparer.OrdinalIgnoreCase))
        {
            if (SourceUris.SchemeOf(t.SourceUri) == SourceUris.File) continue;
            if (!string.IsNullOrEmpty(t.LocalCopyPath) && File.Exists(t.LocalCopyPath)) continue;
            Entry? existing;
            lock (_gate) existing = _entries.FirstOrDefault(e => e.Item.Kind == DownloadKind.Offline && string.Equals(e.Item.SourceUri, t.SourceUri, StringComparison.OrdinalIgnoreCase));
            if (existing is not null)
            {
                if (existing.Item.State is DownloadState.Failed or DownloadState.Canceled or DownloadState.Paused) Retry(existing.Item.Id);
                else if (existing.Item.State == DownloadState.Completed && !File.Exists(existing.Item.DestinationPath)) Retry(existing.Item.Id);
                added.Add(existing.Item.Clone());
                continue;
            }
            var item = new DownloadItem
            {
                SourceUri = t.SourceUri, TrackId = t.Id > 0 ? t.Id : null, Title = t.DisplayTitle, Artist = t.Artist ?? t.AlbumArtist,
                Kind = DownloadKind.Offline, State = DownloadState.Queued, TotalBytes = t.FileSize,
                DestinationPath = Path.Combine(_paths.OfflineDirectory, HashName(t.SourceUri) + ExtensionFor(t))
            };
            added.Add(await AddEntryAsync(item, t, ct).ConfigureAwait(false));
        }
        if (added.Count > 0) ItemsChanged?.Invoke(this, EventArgs.Empty);
        Pump();
        return added;
    }

    public async Task RemoveOfflineCopyAsync(Track track, CancellationToken ct = default)
    {
        List<Entry> matches;
        lock (_gate) matches = _entries.Where(e => e.Item.Kind == DownloadKind.Offline && string.Equals(e.Item.SourceUri, track.SourceUri, StringComparison.OrdinalIgnoreCase)).ToList();
        foreach (var m in matches) await RemoveAsync(m.Item.Id, deleteFile: true).ConfigureAwait(false);
        if (!string.IsNullOrEmpty(track.LocalCopyPath) && track.LocalCopyPath.StartsWith(_paths.OfflineDirectory, StringComparison.OrdinalIgnoreCase))
            TryDelete(track.LocalCopyPath);
        await _tracks.SetLocalCopyAsync(track.SourceUri, null, ct).ConfigureAwait(false);
        OfflineCopyChanged?.Invoke(this, (track.SourceUri, null));
    }

    public async Task<IReadOnlyList<DownloadItem>> DownloadToFolderAsync(IEnumerable<Track> tracks, string? folder = null, CancellationToken ct = default)
    {
        var dir = ResolveFolder(folder);
        var added = new List<DownloadItem>();
        foreach (var t in tracks.DistinctBy(t => t.SourceUri, StringComparer.OrdinalIgnoreCase))
        {
            var name = FileSystemSourceBase.SanitizeName(string.IsNullOrWhiteSpace(t.Artist) ? t.DisplayTitle : $"{t.Artist} - {t.DisplayTitle}") + ExtensionFor(t);
            var item = new DownloadItem
            {
                SourceUri = t.SourceUri, TrackId = t.Id > 0 ? t.Id : null, Title = t.DisplayTitle, Artist = t.Artist ?? t.AlbumArtist,
                Kind = DownloadKind.Export, State = DownloadState.Queued, TotalBytes = t.FileSize,
                DestinationPath = UniquePath(Path.Combine(dir, name))
            };
            added.Add(await AddEntryAsync(item, t, ct).ConfigureAwait(false));
        }
        if (added.Count > 0) ItemsChanged?.Invoke(this, EventArgs.Empty);
        Pump();
        return added;
    }

    public async Task<DownloadItem> DownloadUriAsync(string sourceUri, string? fileName = null, string? folder = null, CancellationToken ct = default)
    {
        var dir = ResolveFolder(folder);
        var name = FileSystemSourceBase.SanitizeName(fileName ?? SourceUris.FileNameOf(sourceUri));
        if (string.IsNullOrWhiteSpace(name)) name = "download";
        var item = new DownloadItem
        {
            SourceUri = sourceUri, Title = Path.GetFileNameWithoutExtension(name), Kind = DownloadKind.Export, State = DownloadState.Queued,
            DestinationPath = UniquePath(Path.Combine(dir, name))
        };
        var result = await AddEntryAsync(item, null, ct).ConfigureAwait(false);
        ItemsChanged?.Invoke(this, EventArgs.Empty);
        Pump();
        return result;
    }

    public async Task CacheTrackAsync(Track track, CancellationToken ct = default)
    {
        var s = _settings.Current;
        if (!s.AudioCacheEnabled || s.OfflineMode || s.AudioCacheMaxBytes <= 0) return;
        if (SourceUris.SchemeOf(track.SourceUri) is SourceUris.File or SourceUris.Zip) return;
        if (!string.IsNullOrEmpty(track.FilePath) && File.Exists(track.FilePath)) return;
        if (!string.IsNullOrEmpty(track.LocalCopyPath) && File.Exists(track.LocalCopyPath)) return;
        if (track.FileSize > 0 && track.FileSize > s.AudioCacheMaxBytes / 2) return;
        if (await _cache.GetAsync(track.SourceUri, ct).ConfigureAwait(false) is { } c && File.Exists(c.Path)) return;
        if (!_cacheInFlight.TryAdd(track.SourceUri, 0)) return;
        var item = new DownloadItem
        {
            SourceUri = track.SourceUri, TrackId = track.Id > 0 ? track.Id : null, Title = track.DisplayTitle, Artist = track.Artist,
            Kind = DownloadKind.Cache, State = DownloadState.Queued, TotalBytes = track.FileSize,
            DestinationPath = Path.Combine(_paths.AudioCacheDirectory, HashName(track.SourceUri) + ExtensionFor(track))
        };
        lock (_gate) _entries.Add(new Entry(item, track));
        Pump();
    }

    private async Task<DownloadItem> AddEntryAsync(DownloadItem item, Track? track, CancellationToken ct)
    {
        await _repo.SaveAsync(item, ct).ConfigureAwait(false);
        lock (_gate) _entries.Add(new Entry(item, track));
        return item.Clone();
    }

    private string ResolveFolder(string? folder)
    {
        var dir = folder ?? _settings.Current.DownloadFolder ?? AppPaths.DefaultDownloadFolder;
        Directory.CreateDirectory(dir);
        return dir;
    }

    public void Pause(Guid id)
    {
        Entry? e;
        lock (_gate)
        {
            e = Find(id);
            if (e is null || e.Item.State is DownloadState.Completed or DownloadState.Canceled) return;
            e.Item.State = DownloadState.Paused;
            e.Cts?.Cancel();
        }
        _ = PersistAndNotifyAsync(e, force: true);
        Pump();
    }

    public void Resume(Guid id)
    {
        Entry? e;
        lock (_gate)
        {
            e = Find(id);
            if (e is null || e.Item.State != DownloadState.Paused) return;
            e.Item.State = DownloadState.Queued;
            e.NotBefore = null;
        }
        _ = PersistAndNotifyAsync(e, force: true);
        Pump();
    }

    public void Retry(Guid id)
    {
        Entry? e;
        lock (_gate)
        {
            e = Find(id);
            if (e is null || e.Running) return;
            e.Item.State = DownloadState.Queued;
            e.Item.Error = null;
            e.Item.Attempts = 0;
            e.NotBefore = null;
        }
        _ = PersistAndNotifyAsync(e, force: true);
        Pump();
    }

    public async Task CancelAsync(Guid id)
    {
        Entry? e;
        Task? worker;
        lock (_gate)
        {
            e = Find(id);
            if (e is null || e.Item.State == DownloadState.Completed) return;
            e.Item.State = DownloadState.Canceled;
            e.Cts?.Cancel();
            worker = e.Worker;
        }
        if (worker is not null) await worker.ConfigureAwait(false);
        TryDelete(PartPath(e.Item));
        e.Item.DownloadedBytes = 0;
        await PersistAndNotifyAsync(e, force: true).ConfigureAwait(false);
    }

    public async Task RemoveAsync(Guid id, bool deleteFile = false)
    {
        Entry? e;
        Task? worker;
        lock (_gate)
        {
            e = Find(id);
            if (e is null) return;
            e.Item.State = e.Item.State == DownloadState.Completed ? DownloadState.Completed : DownloadState.Canceled;
            e.Cts?.Cancel();
            worker = e.Worker;
        }
        if (worker is not null) await worker.ConfigureAwait(false);
        lock (_gate) _entries.Remove(e);
        TryDelete(PartPath(e.Item));
        if (deleteFile && e.Item.State == DownloadState.Completed)
        {
            TryDelete(e.Item.DestinationPath);
            if (e.Item.Kind == DownloadKind.Offline)
            {
                await _tracks.SetLocalCopyAsync(e.Item.SourceUri, null).ConfigureAwait(false);
                OfflineCopyChanged?.Invoke(this, (e.Item.SourceUri, null));
            }
        }
        await _repo.DeleteAsync(id).ConfigureAwait(false);
        ItemsChanged?.Invoke(this, EventArgs.Empty);
    }

    public void PauseAll()
    {
        List<Guid> ids;
        lock (_gate) ids = _entries.Where(e => e.Item.Kind != DownloadKind.Cache && e.Item.State is DownloadState.Queued or DownloadState.Downloading).Select(e => e.Item.Id).ToList();
        foreach (var id in ids) Pause(id);
    }

    public void ResumeAll()
    {
        List<Guid> ids;
        lock (_gate) ids = _entries.Where(e => e.Item.State == DownloadState.Paused).Select(e => e.Item.Id).ToList();
        foreach (var id in ids) Resume(id);
    }

    public async Task ClearFinishedAsync(CancellationToken ct = default)
    {
        lock (_gate) _entries.RemoveAll(e => e.Item.State is DownloadState.Completed or DownloadState.Canceled && e.Item.Kind != DownloadKind.Cache);
        await _repo.DeleteCompletedAsync(ct).ConfigureAwait(false);
        ItemsChanged?.Invoke(this, EventArgs.Empty);
    }

    private Entry? Find(Guid id) => _entries.FirstOrDefault(e => e.Item.Id == id);

    /// <summary>Starts workers for queued items while below the concurrency limit. User downloads go before cache fills.</summary>
    private void Pump()
    {
        if (_shutdown.IsCancellationRequested) return;
        var s = _settings.Current;
        var limit = Math.Clamp(s.DownloadConcurrency, 1, 10);
        DateTimeOffset? nextWake = null;
        lock (_gate)
        {
            var running = _entries.Count(e => e.Running);
            var now = DateTimeOffset.UtcNow;
            foreach (var e in _entries.Where(e => e.Item.State == DownloadState.Queued && !e.Running)
                         .OrderBy(e => e.Item.Kind == DownloadKind.Cache ? 1 : 0).ThenBy(e => e.Item.Created).ToList())
            {
                if (running >= limit) break;
                if (s.OfflineMode && SourceUris.SchemeOf(e.Item.SourceUri) is not (SourceUris.File or SourceUris.Smb or SourceUris.Zip)) continue;
                if (e.NotBefore is { } nb && nb > now)
                {
                    nextWake = nextWake is null || nb < nextWake ? nb : nextWake;
                    continue;
                }
                e.Cts = CancellationTokenSource.CreateLinkedTokenSource(_shutdown.Token);
                e.Item.State = DownloadState.Downloading;
                var token = e.Cts.Token;
                e.Worker = Task.Run(() => RunAsync(e, token));
                running++;
            }
        }
        if (nextWake is { } wake)
        {
            var delay = wake - DateTimeOffset.UtcNow;
            _ = Task.Delay(delay < TimeSpan.Zero ? TimeSpan.Zero : delay + TimeSpan.FromMilliseconds(50), _shutdown.Token)
                .ContinueWith(_ => Pump(), TaskContinuationOptions.OnlyOnRanToCompletion);
        }
    }

    private async Task RunAsync(Entry e, CancellationToken ct)
    {
        var item = e.Item;
        await PersistAndNotifyAsync(e, force: true).ConfigureAwait(false);
        try
        {
            item.Attempts++;
            await DownloadAsync(e, ct).ConfigureAwait(false);
            await CompleteAsync(e).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            // Paused, canceled, removed or shutting down: state was set by the caller.
            if (_shutdown.IsCancellationRequested && item.State == DownloadState.Downloading) item.State = DownloadState.Queued;
        }
        catch (Exception ex)
        {
            var permanent = ex is SourceAuthenticationException or OfflineException or OAuthNotConfiguredException or UnauthorizedAccessException
                || (ex is SourceException && ex.InnerException is null && ex.Message.StartsWith("No configured source", StringComparison.Ordinal))
                || (ex is HttpRequestException h && h.StatusCode is System.Net.HttpStatusCode.NotFound or System.Net.HttpStatusCode.Forbidden or System.Net.HttpStatusCode.Unauthorized);
            item.Error = ex.Message;
            if (!permanent && item.Attempts < MaxAttempts)
            {
                var backoff = TimeSpan.FromSeconds(Math.Min(120, Math.Pow(2, item.Attempts)));
                _log.LogInformation("Download {Title} failed (attempt {Attempt}), retrying in {Delay}s: {Error}", item.Title, item.Attempts, backoff.TotalSeconds, ex.Message);
                item.State = DownloadState.Queued;
                e.NotBefore = DateTimeOffset.UtcNow + backoff;
            }
            else
            {
                _log.LogWarning(ex, "Download {Title} failed", item.Title);
                item.State = DownloadState.Failed;
            }
        }
        finally
        {
            item.BytesPerSecond = 0;
            item.Updated = DateTimeOffset.UtcNow;
            if (item.Kind == DownloadKind.Cache && item.State is not (DownloadState.Queued or DownloadState.Downloading))
            {
                lock (_gate) _entries.Remove(e);
                _cacheInFlight.TryRemove(item.SourceUri, out _);
            }
            if (!_shutdown.IsCancellationRequested || item.Kind != DownloadKind.Cache)
            {
                try { await PersistAndNotifyAsync(e, force: true).ConfigureAwait(false); }
                catch (Exception ex) { _log.LogDebug(ex, "Persist failed"); }
            }
            lock (_gate) e.Worker = null;
            Pump();
        }
    }

    private async Task DownloadAsync(Entry e, CancellationToken ct)
    {
        var item = e.Item;
        var location = e.Track is { } t && item.Kind == DownloadKind.Cache
            ? await _sources.ResolveAsync(t.SourceUri, ct).ConfigureAwait(false)
            : await _sources.ResolveAsync(item.SourceUri, ct).ConfigureAwait(false);
        if (location.Length > 0) item.TotalBytes = location.Length;
        var part = PartPath(item);
        Directory.CreateDirectory(Path.GetDirectoryName(part)!);
        long offset = File.Exists(part) ? new FileInfo(part).Length : 0;
        if (item.TotalBytes > 0 && offset > item.TotalBytes) { TryDelete(part); offset = 0; }
        if (item.TotalBytes > 0 && offset == item.TotalBytes) { item.DownloadedBytes = offset; return; }

        var http = _httpFactory.CreateClient(HttpClientNames.Default);
        await using var src = await location.OpenReadAsync(http, offset, ct).ConfigureAwait(false);
        await using var dst = new FileStream(part, offset > 0 ? FileMode.Append : FileMode.Create, FileAccess.Write, FileShare.Read, 1 << 16, FileOptions.Asynchronous);
        item.DownloadedBytes = offset;
        var buffer = new byte[1 << 17];
        var sw = Stopwatch.StartNew();
        long windowBytes = 0;
        var windowStart = sw.Elapsed;
        using var stall = CancellationTokenSource.CreateLinkedTokenSource(ct);
        while (true)
        {
            stall.CancelAfter(ReadStallTimeout);
            int n;
            try
            {
                n = await src.ReadAsync(buffer, stall.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested)
            {
                throw new IOException("The connection stalled.");
            }
            if (n == 0) break;
            await dst.WriteAsync(buffer.AsMemory(0, n), ct).ConfigureAwait(false);
            item.DownloadedBytes += n;
            windowBytes += n;
            var elapsed = sw.Elapsed - windowStart;
            if (elapsed >= TimeSpan.FromSeconds(1))
            {
                item.BytesPerSecond = windowBytes / elapsed.TotalSeconds;
                windowBytes = 0;
                windowStart = sw.Elapsed;
            }
            await PersistAndNotifyAsync(e, force: false).ConfigureAwait(false);
        }
        await dst.FlushAsync(ct).ConfigureAwait(false);
        if (item.TotalBytes > 0 && item.DownloadedBytes < item.TotalBytes)
            throw new IOException($"The download ended early ({item.DownloadedBytes} of {item.TotalBytes} bytes).");
        if (item.TotalBytes <= 0) item.TotalBytes = item.DownloadedBytes;
    }

    private async Task CompleteAsync(Entry e)
    {
        var item = e.Item;
        var part = PartPath(item);
        Directory.CreateDirectory(Path.GetDirectoryName(item.DestinationPath)!);
        if (item.Kind == DownloadKind.Export && File.Exists(item.DestinationPath)) item.DestinationPath = UniquePath(item.DestinationPath);
        File.Move(part, item.DestinationPath, overwrite: true);
        item.State = DownloadState.Completed;
        item.Error = null;
        item.DownloadedBytes = item.TotalBytes = new FileInfo(item.DestinationPath).Length;
        switch (item.Kind)
        {
            case DownloadKind.Offline:
                await _tracks.SetLocalCopyAsync(item.SourceUri, item.DestinationPath).ConfigureAwait(false);
                // An offline copy supersedes the cache entry.
                if (await _cache.GetAsync(item.SourceUri).ConfigureAwait(false) is { } c)
                {
                    TryDelete(c.Path);
                    await _cache.DeleteAsync(item.SourceUri).ConfigureAwait(false);
                }
                OfflineCopyChanged?.Invoke(this, (item.SourceUri, item.DestinationPath));
                break;
            case DownloadKind.Cache:
                await _cache.UpsertAsync(item.SourceUri, item.DestinationPath, item.TotalBytes).ConfigureAwait(false);
                await EnforceCacheLimitAsync().ConfigureAwait(false);
                break;
        }
        _log.LogInformation("Download completed: {Title} ({Bytes} bytes, {Kind})", item.Title, item.TotalBytes, item.Kind);
    }

    private async Task PersistAndNotifyAsync(Entry e, bool force)
    {
        var now = Environment.TickCount64;
        var item = e.Item;
        if (force || now - e.LastEventTicks >= 250)
        {
            e.LastEventTicks = now;
            item.Updated = DateTimeOffset.UtcNow;
            if (item.Kind != DownloadKind.Cache) ItemChanged?.Invoke(this, item.Clone());
        }
        if (item.Kind == DownloadKind.Cache) return;
        if (force || now - e.LastPersistTicks >= 2000)
        {
            e.LastPersistTicks = now;
            bool stillListed;
            lock (_gate) stillListed = _entries.Contains(e);
            if (stillListed) await _repo.SaveAsync(item.Clone()).ConfigureAwait(false);
        }
    }

    public Task<long> GetCacheSizeAsync(CancellationToken ct = default) => _cache.GetTotalSizeAsync(ct);

    public async Task ClearCacheAsync(CancellationToken ct = default)
    {
        await _cacheLock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            await _cache.ClearAsync(ct).ConfigureAwait(false);
            foreach (var f in Directory.EnumerateFiles(_paths.AudioCacheDirectory)) TryDelete(f);
        }
        finally { _cacheLock.Release(); }
    }

    public async Task EnforceCacheLimitAsync(CancellationToken ct = default)
    {
        await _cacheLock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            var max = Math.Max(0, _settings.Current.AudioCacheMaxBytes);
            var total = await _cache.GetTotalSizeAsync(ct).ConfigureAwait(false);
            while (total > max)
            {
                var oldest = await _cache.GetOldestAsync(16, ct).ConfigureAwait(false);
                if (oldest.Count == 0) break;
                foreach (var (uri, path, size) in oldest)
                {
                    if (total <= max) break;
                    TryDelete(path);
                    await _cache.DeleteAsync(uri, ct).ConfigureAwait(false);
                    total -= size;
                }
            }
        }
        finally { _cacheLock.Release(); }
    }

    public long GetOfflineSize()
    {
        try { return new DirectoryInfo(_paths.OfflineDirectory).EnumerateFiles("*", SearchOption.AllDirectories).Sum(f => f.Length); }
        catch (IOException) { return 0; }
    }

    private string PartPath(DownloadItem item) => Path.Combine(_paths.DownloadsTempDirectory, item.Id.ToString("N") + ".part");

    internal static string HashName(string uri) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(uri.ToLowerInvariant())), 0, 12).ToLowerInvariant();

    private static string ExtensionFor(Track t)
    {
        var ext = Path.GetExtension(t.FileName);
        if (string.IsNullOrEmpty(ext)) ext = Path.GetExtension(SourceUris.FileNameOf(t.SourceUri));
        if (string.IsNullOrEmpty(ext) || ext.Length > 6)
            ext = t.Format is { Length: > 0 and <= 5 } f ? "." + f : ExtensionForCodec(t.Codec);
        return ext.ToLowerInvariant();
    }

    private static string ExtensionForCodec(string? codec) => codec?.ToUpperInvariant() switch
    {
        "FLAC" => ".flac",
        "ALAC" or "AAC" => ".m4a",
        "MP3" => ".mp3",
        "OPUS" => ".opus",
        "VORBIS" => ".ogg",
        "WMA" => ".wma",
        "APE" => ".ape",
        "WAVPACK" => ".wv",
        { } c when c.StartsWith("PCM", StringComparison.Ordinal) => ".wav",
        { } c when c.StartsWith("DSD", StringComparison.Ordinal) => ".dsf",
        _ => ".audio"
    };

    internal static string UniquePath(string path)
    {
        if (!File.Exists(path)) return path;
        var dir = Path.GetDirectoryName(path)!;
        var stem = Path.GetFileNameWithoutExtension(path);
        var ext = Path.GetExtension(path);
        for (var i = 2; ; i++)
        {
            var candidate = Path.Combine(dir, $"{stem} ({i}){ext}");
            if (!File.Exists(candidate)) return candidate;
        }
    }

    private void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { _log.LogDebug(ex, "Could not delete {Path}", path); }
    }

    public async ValueTask DisposeAsync()
    {
        _shutdown.Cancel();
        Task[] workers;
        lock (_gate) workers = _entries.Select(e => e.Worker).OfType<Task>().ToArray();
        try { await Task.WhenAll(workers).WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false); }
        catch (Exception ex) when (ex is TimeoutException or OperationCanceledException) { }
        _shutdown.Dispose();
    }
}
