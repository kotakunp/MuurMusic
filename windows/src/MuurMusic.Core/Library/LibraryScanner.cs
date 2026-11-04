using System.Collections.Concurrent;
using System.Diagnostics;
using Microsoft.Extensions.Logging;
using MuurMusic.Core.Data;
using MuurMusic.Core.Models;
using MuurMusic.Core.Playlists;
using MuurMusic.Core.Settings;
using MuurMusic.Core.Sources;
using MuurMusic.Core.Tags;

namespace MuurMusic.Core.Library;

public enum ScanPhase { Enumerating, Reading, Saving, Cleaning, Done }

/// <summary>Scan progress snapshot (raised at most ~10 times per second).</summary>
public sealed record ScanProgress(ScanPhase Phase, int FilesFound, int FilesToRead, int FilesRead, int Added, int Updated, int Removed, string? CurrentPath)
{
    public double Fraction => Phase switch
    {
        ScanPhase.Enumerating => 0,
        ScanPhase.Reading => FilesToRead == 0 ? 1 : (double)FilesRead / FilesToRead,
        _ => 1
    };
}

public sealed record ScanResult(int Added, int Updated, int Removed, int Unchanged, int Failed, TimeSpan Elapsed, bool Canceled);

/// <summary>Library scanner: incremental (mtime/size) scans of watched folders with parallel tag reading, artwork, CUE expansion,
/// sidecar lyrics detection and live FileSystemWatcher updates.</summary>
public interface ILibraryScanner : IDisposable
{
    bool IsScanning { get; }
    /// <summary>Raised on a background thread.</summary>
    event EventHandler<ScanProgress>? Progress;
    event EventHandler<ScanResult>? ScanCompleted;
    /// <summary>Raised after any change to library tracks (scan, watcher update, folder removal).</summary>
    event EventHandler? LibraryChanged;
    /// <summary>Scans folders (default: all watched folders). <paramref name="full"/> re-reads every file regardless of mtime.</summary>
    Task<ScanResult> ScanAsync(IEnumerable<string>? folders = null, bool full = false, CancellationToken ct = default);
    /// <summary>Re-reads specific files (e.g. after tag editing).</summary>
    Task<ScanResult> ScanFilesAsync(IEnumerable<string> files, CancellationToken ct = default);
    /// <summary>Adds a folder to the watched list and scans it.</summary>
    Task<ScanResult> AddFolderAsync(string folder, CancellationToken ct = default);
    /// <summary>Removes a folder from the watched list and deletes its tracks from the library.</summary>
    Task RemoveFolderAsync(string folder, CancellationToken ct = default);
    void CancelScan();
    /// <summary>Starts FileSystemWatchers for all watched folders (no-op when WatchForChanges is off).</summary>
    void StartWatching();
    void StopWatching();
}

public sealed class LibraryScanner : ILibraryScanner
{
    private readonly ITrackRepository _repo;
    private readonly ITagService _tags;
    private readonly IArtworkCache _artwork;
    private readonly ISettingsService _settings;
    private readonly IMediaProbe? _probe;
    private readonly ILogger<LibraryScanner> _log;
    private readonly SemaphoreSlim _scanLock = new(1, 1);
    private readonly List<FileSystemWatcher> _watchers = new();
    private readonly ConcurrentDictionary<string, byte> _pendingChanges = new(StringComparer.OrdinalIgnoreCase);
    private readonly Timer _debounce;
    private CancellationTokenSource? _scanCts;
    private long _lastProgressTicks;

    public LibraryScanner(ITrackRepository repo, ITagService tags, IArtworkCache artwork, ISettingsService settings, ILogger<LibraryScanner> log, IMediaProbe? probe = null)
    {
        _repo = repo;
        _tags = tags;
        _artwork = artwork;
        _settings = settings;
        _probe = probe;
        _log = log;
        _debounce = new Timer(_ => _ = ProcessPendingAsync(), null, Timeout.Infinite, Timeout.Infinite);
        _settings.Changed += OnSettingsChanged;
    }

    public bool IsScanning { get; private set; }
    public event EventHandler<ScanProgress>? Progress;
    public event EventHandler<ScanResult>? ScanCompleted;
    public event EventHandler? LibraryChanged;

    private void OnSettingsChanged(object? sender, SettingsChangedEventArgs e)
    {
        if (!e.New.WatchedFolders.SequenceEqual(e.Old.WatchedFolders, StringComparer.OrdinalIgnoreCase) ||
            e.New.WatchForChanges != e.Old.WatchForChanges)
        {
            StopWatching();
            StartWatching();
        }
    }

    public void CancelScan() => _scanCts?.Cancel();

    public async Task<ScanResult> AddFolderAsync(string folder, CancellationToken ct = default)
    {
        var full = Path.GetFullPath(folder);
        if (!Directory.Exists(full)) throw new DirectoryNotFoundException(full);
        _settings.Update(s =>
        {
            if (!s.WatchedFolders.Contains(full, StringComparer.OrdinalIgnoreCase)) s.WatchedFolders.Add(full);
            s.ExcludedFolders.RemoveAll(x => x.Equals(full, StringComparison.OrdinalIgnoreCase));
        });
        return await ScanAsync(new[] { full }, false, ct).ConfigureAwait(false);
    }

    public async Task RemoveFolderAsync(string folder, CancellationToken ct = default)
    {
        var full = Path.GetFullPath(folder);
        _settings.Update(s => s.WatchedFolders.RemoveAll(x => x.Equals(full, StringComparison.OrdinalIgnoreCase)));
        var stillCovered = _settings.Current.WatchedFolders.Any(w => IsUnder(full, w));
        if (!stillCovered)
        {
            var index = await _repo.GetFileIndexAsync(full, ct).ConfigureAwait(false);
            if (index.Count > 0) await _repo.DeleteByFilePathsAsync(index.Keys, ct).ConfigureAwait(false);
        }
        LibraryChanged?.Invoke(this, EventArgs.Empty);
    }

    private static bool IsUnder(string path, string root)
    {
        var r = Path.GetFullPath(root).TrimEnd('\\') + "\\";
        return (Path.GetFullPath(path).TrimEnd('\\') + "\\").StartsWith(r, StringComparison.OrdinalIgnoreCase);
    }

    private bool IsExcluded(string path) => _settings.Current.ExcludedFolders.Any(x => IsUnder(path, x));

    public async Task<ScanResult> ScanAsync(IEnumerable<string>? folders = null, bool full = false, CancellationToken ct = default)
    {
        var roots = (folders ?? _settings.Current.WatchedFolders).Select(Path.GetFullPath).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        // Drop roots nested inside other roots in the same request.
        roots = roots.Where(r => !roots.Any(o => !o.Equals(r, StringComparison.OrdinalIgnoreCase) && IsUnder(r, o))).ToList();
        await _scanLock.WaitAsync(ct).ConfigureAwait(false);
        _scanCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        var token = _scanCts.Token;
        IsScanning = true;
        var sw = Stopwatch.StartNew();
        var stats = new ScanStats();
        try
        {
            foreach (var root in roots)
            {
                token.ThrowIfCancellationRequested();
                if (!Directory.Exists(root))
                {
                    _log.LogInformation("Watched folder {Root} is not available; keeping its tracks", root);
                    continue;
                }
                await ScanRootAsync(root, full, stats, token).ConfigureAwait(false);
            }
            var result = new ScanResult(stats.Added, stats.Updated, stats.Removed, stats.Unchanged, stats.Failed, sw.Elapsed, false);
            Report(new ScanProgress(ScanPhase.Done, stats.Found, stats.ToRead, stats.Read, stats.Added, stats.Updated, stats.Removed, null), force: true);
            ScanCompleted?.Invoke(this, result);
            if (stats.Added + stats.Updated + stats.Removed > 0) LibraryChanged?.Invoke(this, EventArgs.Empty);
            return result;
        }
        catch (OperationCanceledException)
        {
            var result = new ScanResult(stats.Added, stats.Updated, stats.Removed, stats.Unchanged, stats.Failed, sw.Elapsed, true);
            ScanCompleted?.Invoke(this, result);
            if (stats.Added + stats.Updated + stats.Removed > 0) LibraryChanged?.Invoke(this, EventArgs.Empty);
            if (ct.IsCancellationRequested) throw;
            return result;
        }
        finally
        {
            IsScanning = false;
            _scanCts.Dispose();
            _scanCts = null;
            _scanLock.Release();
        }
    }

    private sealed class ScanStats
    {
        public int Found, ToRead, Read, Added, Updated, Removed, Unchanged, Failed;
    }

    private void Report(ScanProgress p, bool force = false)
    {
        var now = Environment.TickCount64;
        if (!force && now - Interlocked.Read(ref _lastProgressTicks) < 100) return;
        Interlocked.Exchange(ref _lastProgressTicks, now);
        Progress?.Invoke(this, p);
    }

    /// <summary>A unit of work: one audio file with the CUE sheet (external or embedded) that applies to it.</summary>
    private sealed record WorkItem(string AudioPath, FileInfo Info, string? CuePath, CueSheet? Cue, long EffectiveMtime);

    private async Task ScanRootAsync(string root, bool full, ScanStats stats, CancellationToken ct)
    {
        Report(new ScanProgress(ScanPhase.Enumerating, stats.Found, 0, 0, stats.Added, stats.Updated, stats.Removed, root), force: true);
        var (audio, cues) = await Task.Run(() => Enumerate(root, stats, ct), ct).ConfigureAwait(false);
        var index = await _repo.GetFileIndexAsync(root, ct).ConfigureAwait(false);
        var work = BuildWork(audio, cues);
        var toRead = new List<WorkItem>();
        foreach (var w in work)
        {
            if (!full && index.TryGetValue(w.AudioPath, out var known) && known.Mtime == w.EffectiveMtime && known.Size == w.Info.Length)
            {
                stats.Unchanged++;
                continue;
            }
            toRead.Add(w);
        }
        stats.ToRead += toRead.Count;
        await ProcessAsync(toRead, index, stats, ct, isNetwork: root.StartsWith(@"\\", StringComparison.Ordinal)).ConfigureAwait(false);

        Report(new ScanProgress(ScanPhase.Cleaning, stats.Found, stats.ToRead, stats.Read, stats.Added, stats.Updated, stats.Removed, root), force: true);
        var seen = new HashSet<string>(work.Select(w => w.AudioPath), StringComparer.OrdinalIgnoreCase);
        var gone = index.Keys.Where(k => !seen.Contains(k) && !IsUnderAnyOtherRoot(k, root)).ToList();
        if (gone.Count > 0)
            stats.Removed += await _repo.DeleteByFilePathsAsync(gone, ct).ConfigureAwait(false);
    }

    private bool IsUnderAnyOtherRoot(string path, string currentRoot) =>
        _settings.Current.WatchedFolders.Any(w => !w.Equals(currentRoot, StringComparison.OrdinalIgnoreCase) && IsUnder(path, w) && !IsUnder(path, currentRoot));

    private (List<FileInfo> Audio, List<FileInfo> Cues) Enumerate(string root, ScanStats stats, CancellationToken ct)
    {
        var audio = new List<FileInfo>();
        var cues = new List<FileInfo>();
        var options = new EnumerationOptions { IgnoreInaccessible = true, RecurseSubdirectories = false, AttributesToSkip = FileAttributes.Hidden | FileAttributes.System };
        var stack = new Stack<DirectoryInfo>();
        stack.Push(new DirectoryInfo(root));
        while (stack.Count > 0)
        {
            ct.ThrowIfCancellationRequested();
            var dir = stack.Pop();
            if (IsExcluded(dir.FullName)) continue;
            try
            {
                foreach (var e in dir.EnumerateFileSystemInfos("*", options))
                {
                    if (e is DirectoryInfo d)
                    {
                        if ((d.Attributes & FileAttributes.ReparsePoint) == 0) stack.Push(d);
                        continue;
                    }
                    if (e is not FileInfo f) continue;
                    if (AudioFormats.IsAudioFile(f.Name)) { audio.Add(f); stats.Found++; }
                    else if (f.Extension.Equals(".cue", StringComparison.OrdinalIgnoreCase)) cues.Add(f);
                }
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Security.SecurityException)
            {
                _log.LogDebug(ex, "Cannot enumerate {Dir}", dir.FullName);
            }
            if (stats.Found % 200 == 0) Report(new ScanProgress(ScanPhase.Enumerating, stats.Found, 0, 0, stats.Added, stats.Updated, stats.Removed, dir.FullName));
        }
        return (audio, cues);
    }

    private List<WorkItem> BuildWork(List<FileInfo> audio, List<FileInfo> cues)
    {
        var cueFor = new Dictionary<string, (string CuePath, CueSheet Sheet, long Mtime)>(StringComparer.OrdinalIgnoreCase);
        if (_settings.Current.ExpandCueSheets)
        {
            foreach (var cue in cues)
            {
                try
                {
                    var sheet = CueSheet.Load(cue.FullName);
                    foreach (var file in sheet.Files)
                    {
                        var resolved = CueSheet.ResolveAudioFile(cue.DirectoryName!, file.FileName);
                        if (resolved is null) continue;
                        var mtime = new DateTimeOffset(cue.LastWriteTimeUtc).ToUnixTimeMilliseconds();
                        cueFor[Path.GetFullPath(resolved)] = (cue.FullName, sheet, mtime);
                    }
                }
                catch (Exception ex) when (ex is IOException or FormatException or UnauthorizedAccessException)
                {
                    _log.LogDebug(ex, "Invalid CUE sheet {Cue}", cue.FullName);
                }
            }
        }
        var list = new List<WorkItem>(audio.Count);
        foreach (var f in audio)
        {
            var mtime = new DateTimeOffset(f.LastWriteTimeUtc).ToUnixTimeMilliseconds();
            if (cueFor.TryGetValue(f.FullName, out var c))
                list.Add(new WorkItem(f.FullName, f, c.CuePath, c.Sheet, Math.Max(mtime, c.Mtime)));
            else
                list.Add(new WorkItem(f.FullName, f, null, null, mtime));
        }
        return list;
    }

    private async Task ProcessAsync(IReadOnlyList<WorkItem> items, IReadOnlyDictionary<string, (long Mtime, long Size)> index, ScanStats stats, CancellationToken ct, bool isNetwork)
    {
        if (items.Count == 0) return;
        var folderArt = new ConcurrentDictionary<string, Task<string?>>(StringComparer.OrdinalIgnoreCase);
        var batch = new List<(WorkItem Item, List<Track> Tracks)>();
        var batchLock = new object();
        var parallel = new ParallelOptions { CancellationToken = ct, MaxDegreeOfParallelism = isNetwork ? 4 : Math.Clamp(Environment.ProcessorCount, 2, 8) };

        await Parallel.ForEachAsync(items, parallel, async (item, token) =>
        {
            List<Track> tracks;
            try
            {
                tracks = await ReadItemAsync(item, folderArt, token).ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                _log.LogWarning(ex, "Failed to read {Path}", item.AudioPath);
                Interlocked.Increment(ref stats.Failed);
                tracks = new List<Track>();
            }
            var read = Interlocked.Increment(ref stats.Read);
            Report(new ScanProgress(ScanPhase.Reading, stats.Found, stats.ToRead, read, stats.Added, stats.Updated, stats.Removed, item.AudioPath));
            List<(WorkItem, List<Track>)>? flush = null;
            lock (batchLock)
            {
                batch.Add((item, tracks));
                if (batch.Count >= 100)
                {
                    flush = batch.ToList();
                    batch.Clear();
                }
            }
            if (flush is not null) await SaveAsync(flush, index, stats, token).ConfigureAwait(false);
        }).ConfigureAwait(false);
        if (batch.Count > 0) await SaveAsync(batch, index, stats, ct).ConfigureAwait(false);
    }

    private readonly SemaphoreSlim _saveLock = new(1, 1);

    private async Task SaveAsync(List<(WorkItem Item, List<Track> Tracks)> batch, IReadOnlyDictionary<string, (long Mtime, long Size)> index, ScanStats stats, CancellationToken ct)
    {
        await _saveLock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            var all = batch.SelectMany(b => b.Tracks).ToList();
            if (all.Count > 0) await _repo.UpsertAsync(all, ct).ConfigureAwait(false);
            foreach (var (item, tracks) in batch)
            {
                if (tracks.Count == 0)
                {
                    // Unreadable or too short: make sure no stale rows stay behind.
                    if (index.ContainsKey(item.AudioPath)) await _repo.DeleteByFilePathsAsync(new[] { item.AudioPath }, ct).ConfigureAwait(false);
                    continue;
                }
                await _repo.DeleteStaleCueTracksAsync(tracks[0].SourceUri, tracks.Select(t => t.CueStartMs).ToList(), ct).ConfigureAwait(false);
                if (index.ContainsKey(item.AudioPath)) Interlocked.Increment(ref stats.Updated);
                else Interlocked.Increment(ref stats.Added);
            }
        }
        finally { _saveLock.Release(); }
    }

    private async Task<List<Track>> ReadItemAsync(WorkItem item, ConcurrentDictionary<string, Task<string?>> folderArt, CancellationToken ct)
    {
        var path = item.AudioPath;
        var read = _tags.Read(path);
        Track baseTrack;
        byte[]? embeddedArt = null;
        string? embeddedCue = null;
        if (read is not null)
        {
            baseTrack = read.Track;
            embeddedArt = read.Artwork;
            embeddedCue = read.EmbeddedCueSheet;
        }
        else if (_probe is not null && await _probe.ProbeAsync(path, null, ct).ConfigureAwait(false) is { } probe)
        {
            baseTrack = FromProbe(path, item.Info, probe);
            embeddedArt = probe.Artwork;
        }
        else
        {
            baseTrack = FromFileName(path, item.Info);
        }
        baseTrack.FileModifiedMs = item.EffectiveMtime;
        baseTrack.FileSize = item.Info.Length;
        baseTrack.IsRemote = false;
        baseTrack.SourceId = null;
        if (baseTrack.DurationMs <= 0 && _probe is not null && read is not null &&
            await _probe.ProbeAsync(path, null, ct).ConfigureAwait(false) is { } p2)
        {
            baseTrack.DurationMs = (long)p2.Duration.TotalMilliseconds;
            if (baseTrack.SampleRate == 0) baseTrack.SampleRate = p2.SampleRate;
            if (baseTrack.Channels == 0) baseTrack.Channels = p2.Channels;
        }

        string? artHash = null;
        if (embeddedArt is { Length: > 0 }) artHash = await _artwork.StoreAsync(embeddedArt, ct).ConfigureAwait(false);
        else
        {
            var folder = item.Info.DirectoryName!;
            artHash = await folderArt.GetOrAdd(folder, f => FolderArtAsync(f, ct)).ConfigureAwait(false);
        }
        baseTrack.ArtworkHash = artHash;
        baseTrack.HasLyrics = baseTrack.HasLyrics || HasSidecarLyrics(path);

        CueSheet? cue = item.Cue;
        var cuePath = item.CuePath;
        if (cue is null && embeddedCue is not null && _settings.Current.ExpandCueSheets)
        {
            try { cue = CueSheet.Parse(embeddedCue); cuePath = path; }
            catch (FormatException) { cue = null; }
        }
        if (cue is not null)
        {
            var expanded = ExpandCue(baseTrack, cue, cuePath!, path);
            if (expanded.Count > 0) return expanded;
        }
        var min = _settings.Current.MinTrackSeconds;
        if (min > 0 && baseTrack.DurationMs > 0 && baseTrack.DurationMs < min * 1000L) return new List<Track>();
        return new List<Track> { baseTrack };
    }

    private async Task<string?> FolderArtAsync(string folder, CancellationToken ct)
    {
        var image = _artwork.FindFolderImage(folder);
        if (image is null) return null;
        try
        {
            var bytes = await File.ReadAllBytesAsync(image, ct).ConfigureAwait(false);
            return await _artwork.StoreAsync(bytes, ct).ConfigureAwait(false);
        }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
    }

    private static bool HasSidecarLyrics(string path)
    {
        var stem = Path.Combine(Path.GetDirectoryName(path)!, Path.GetFileNameWithoutExtension(path));
        return File.Exists(stem + ".lrc") || File.Exists(stem + ".LRC");
    }

    internal static List<Track> ExpandCue(Track baseTrack, CueSheet cue, string cuePath, string audioPath)
    {
        var virtuals = cue.ToVirtualTracks(name => CueSheet.ResolveAudioFile(Path.GetDirectoryName(cuePath)!, name))
            .Where(v => string.Equals(Path.GetFullPath(v.AudioFile), Path.GetFullPath(audioPath), StringComparison.OrdinalIgnoreCase) ||
                        string.Equals(Path.GetFileName(v.AudioFile), Path.GetFileName(audioPath), StringComparison.OrdinalIgnoreCase))
            .ToList();
        var list = new List<Track>();
        foreach (var v in virtuals)
        {
            var t = baseTrack.Clone();
            t.CueStartMs = v.StartMs;
            t.CueEndMs = v.EndMs ?? (baseTrack.DurationMs > v.StartMs ? baseTrack.DurationMs : null);
            t.CueSheetPath = cuePath;
            t.DurationMs = t.CueEndMs is { } end ? end - v.StartMs : Math.Max(0, baseTrack.DurationMs - v.StartMs);
            t.Title = v.Title ?? t.Title;
            t.Artist = v.Performer ?? v.AlbumPerformer ?? t.Artist;
            t.Album = v.AlbumTitle ?? t.Album;
            t.AlbumArtist = v.AlbumPerformer ?? t.AlbumArtist;
            t.Composer = v.Songwriter ?? t.Composer;
            t.Genre = v.Genre ?? t.Genre;
            if (v.Date is { Length: >= 4 } d && int.TryParse(d[..4], out var y)) t.Year = y;
            t.TrackNumber = v.Number;
            t.TrackTotal = v.TrackCount;
            t.HasLyrics = false;
            list.Add(t);
        }
        return list;
    }

    private static Track FromFileName(string path, FileInfo fi) => new()
    {
        SourceUri = SourceUris.FromLocalPath(path), FilePath = fi.FullName, Folder = fi.DirectoryName, FileName = fi.Name,
        Title = Path.GetFileNameWithoutExtension(fi.Name), Format = fi.Extension.TrimStart('.').ToLowerInvariant(),
        Codec = AudioFormats.CodecFromExtension(path), FileSize = fi.Length
    };

    private static Track FromProbe(string path, FileInfo fi, MediaProbeResult p)
    {
        var t = FromFileName(path, fi);
        string? Tag(string k) => p.Tags.TryGetValue(k, out var v) && !string.IsNullOrWhiteSpace(v) ? v.Trim() : null;
        int? Num(string k) => Tag(k) is { } s && int.TryParse(s.Split('/')[0], out var n) && n > 0 ? n : null;
        t.Title = Tag("TITLE") ?? t.Title;
        t.Artist = Tag("ARTIST");
        t.Album = Tag("ALBUM");
        t.AlbumArtist = Tag("ALBUM_ARTIST") ?? Tag("ALBUMARTIST");
        t.Genre = Tag("GENRE");
        t.Composer = Tag("COMPOSER");
        t.Comment = Tag("COMMENT");
        t.Year = Tag("DATE") is { Length: >= 4 } d && int.TryParse(d[..4], out var y) ? y : Num("YEAR");
        t.TrackNumber = Num("TRACK") ?? Num("TRACKNUMBER");
        t.DiscNumber = Num("DISC") ?? Num("DISCNUMBER");
        t.HasLyrics = Tag("LYRICS") is not null;
        t.DurationMs = (long)p.Duration.TotalMilliseconds;
        t.SampleRate = p.SampleRate;
        t.Channels = p.Channels;
        t.BitDepth = p.BitDepth;
        t.Bitrate = p.BitrateKbps;
        t.Codec = p.Codec ?? t.Codec;
        t.ReplayGainTrackGain = p.ReplayGainTrackGain;
        t.ReplayGainTrackPeak = p.ReplayGainTrackPeak;
        t.ReplayGainAlbumGain = p.ReplayGainAlbumGain;
        t.ReplayGainAlbumPeak = p.ReplayGainAlbumPeak;
        if (!AudioFormats.IsLosslessCodec(t.Codec)) t.BitDepth = 0;
        return t;
    }

    public async Task<ScanResult> ScanFilesAsync(IEnumerable<string> files, CancellationToken ct = default)
    {
        var sw = Stopwatch.StartNew();
        var stats = new ScanStats();
        var existing = new List<FileInfo>();
        var deleted = new List<string>();
        var cueChanged = new List<FileInfo>();
        foreach (var f in files.Select(Path.GetFullPath).Distinct(StringComparer.OrdinalIgnoreCase))
        {
            if (IsExcluded(f)) continue;
            if (File.Exists(f))
            {
                var fi = new FileInfo(f);
                if (AudioFormats.IsAudioFile(f)) existing.Add(fi);
                else if (fi.Extension.Equals(".cue", StringComparison.OrdinalIgnoreCase)) cueChanged.Add(fi);
                else if (fi.Extension.Equals(".lrc", StringComparison.OrdinalIgnoreCase))
                {
                    foreach (var ext in AudioFormats.AudioExtensions)
                    {
                        var audio = Path.ChangeExtension(f, ext);
                        if (File.Exists(audio)) existing.Add(new FileInfo(audio));
                    }
                }
            }
            else deleted.Add(f);
        }
        // A changed CUE sheet affects the audio files it references.
        foreach (var cue in cueChanged)
        {
            try
            {
                foreach (var file in CueSheet.Load(cue.FullName).Files)
                    if (CueSheet.ResolveAudioFile(cue.DirectoryName!, file.FileName) is { } a) existing.Add(new FileInfo(a));
            }
            catch (Exception ex) when (ex is IOException or FormatException) { _log.LogDebug(ex, "Invalid CUE {Cue}", cue.FullName); }
        }
        await _scanLock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (deleted.Count > 0) stats.Removed += await _repo.DeleteByFilePathsAsync(deleted, ct).ConfigureAwait(false);
            var folders = existing.Select(e => e.DirectoryName!).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
            var cues = folders.SelectMany(d =>
            {
                try { return new DirectoryInfo(d).EnumerateFiles("*.cue").ToList(); }
                catch (IOException) { return new List<FileInfo>(); }
            }).ToList();
            var work = BuildWork(existing.DistinctBy(e => e.FullName, StringComparer.OrdinalIgnoreCase).ToList(), cues);
            var index = new Dictionary<string, (long, long)>(StringComparer.OrdinalIgnoreCase);
            foreach (var w in work)
                if ((await _repo.GetByFilePathAsync(w.AudioPath, ct).ConfigureAwait(false)).FirstOrDefault() is { } t) index[w.AudioPath] = (t.FileModifiedMs, t.FileSize);
            stats.ToRead = work.Count;
            await ProcessAsync(work, index, stats, ct, false).ConfigureAwait(false);
        }
        finally { _scanLock.Release(); }
        var result = new ScanResult(stats.Added, stats.Updated, stats.Removed, 0, stats.Failed, sw.Elapsed, false);
        if (stats.Added + stats.Updated + stats.Removed > 0) LibraryChanged?.Invoke(this, EventArgs.Empty);
        return result;
    }

    public void StartWatching()
    {
        if (!_settings.Current.WatchForChanges) return;
        lock (_watchers)
        {
            if (_watchers.Count > 0) return;
            foreach (var folder in _settings.Current.WatchedFolders.Where(Directory.Exists))
            {
                try
                {
                    var w = new FileSystemWatcher(folder)
                    {
                        IncludeSubdirectories = true,
                        NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName | NotifyFilters.LastWrite | NotifyFilters.Size,
                        InternalBufferSize = 64 * 1024
                    };
                    w.Created += (_, e) => Queue(e.FullPath);
                    w.Changed += (_, e) => Queue(e.FullPath);
                    w.Deleted += (_, e) => Queue(e.FullPath);
                    w.Renamed += (_, e) => { Queue(e.OldFullPath); Queue(e.FullPath); };
                    w.Error += (_, e) =>
                    {
                        _log.LogWarning(e.GetException(), "File watcher overflow for {Folder}; rescanning", folder);
                        _ = Task.Run(() => ScanAsync(new[] { folder }));
                    };
                    w.EnableRaisingEvents = true;
                    _watchers.Add(w);
                }
                catch (Exception ex) when (ex is ArgumentException or IOException or PlatformNotSupportedException)
                {
                    _log.LogWarning(ex, "Cannot watch {Folder}", folder);
                }
            }
        }
    }

    public void StopWatching()
    {
        lock (_watchers)
        {
            foreach (var w in _watchers) w.Dispose();
            _watchers.Clear();
        }
    }

    private void Queue(string path)
    {
        _pendingChanges[path] = 0;
        _debounce.Change(TimeSpan.FromSeconds(2), Timeout.InfiniteTimeSpan);
    }

    private async Task ProcessPendingAsync()
    {
        var paths = _pendingChanges.Keys.ToList();
        foreach (var p in paths) _pendingChanges.TryRemove(p, out _);
        if (paths.Count == 0) return;
        try
        {
            var files = new List<string>();
            var folders = new List<string>();
            foreach (var p in paths)
            {
                if (Directory.Exists(p)) folders.Add(p);
                else if (AudioFormats.IsAudioFile(p) || p.EndsWith(".cue", StringComparison.OrdinalIgnoreCase) || p.EndsWith(".lrc", StringComparison.OrdinalIgnoreCase)) files.Add(p);
                else if (!File.Exists(p) && Path.GetExtension(p).Length == 0)
                {
                    // A deleted directory: remove everything that was below it.
                    var index = await _repo.GetFileIndexAsync(p).ConfigureAwait(false);
                    files.AddRange(index.Keys);
                }
                else if (AudioFormats.ImageExtensions.Contains(Path.GetExtension(p))) folders.Add(Path.GetDirectoryName(p)!);
            }
            if (files.Count > 0) await ScanFilesAsync(files).ConfigureAwait(false);
            foreach (var f in folders.Distinct(StringComparer.OrdinalIgnoreCase)) await ScanAsync(new[] { f }).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException or Microsoft.Data.Sqlite.SqliteException)
        {
            _log.LogWarning(ex, "Failed to apply file system changes");
        }
    }

    public void Dispose()
    {
        _settings.Changed -= OnSettingsChanged;
        StopWatching();
        _debounce.Dispose();
        _scanCts?.Cancel();
    }
}
