using MuurMusic.Core.Models;

namespace MuurMusic.Core.Sources;

/// <summary>Shared implementation for sources reachable through the Windows file system (local drives, UNC shares).</summary>
public abstract class FileSystemSourceBase(SourceConfig config) : MusicSourceBase(config)
{
    public override SourceCapabilities Capabilities => SourceCapabilities.Browse | SourceCapabilities.Search | SourceCapabilities.Write;

    protected static string PathOf(string uri) =>
        SourceUris.TryGetLocalPath(uri, out var p) ? p : throw new SourceException($"Not a file system URI: {uri}");

    protected IReadOnlyList<SourceItem> ListDirectory(string dir, CancellationToken ct)
    {
        var di = new DirectoryInfo(dir);
        if (!di.Exists) throw new SourceException($"Folder not found: {dir}");
        var items = new List<SourceItem>();
        try
        {
            foreach (var e in di.EnumerateFileSystemInfos("*", new EnumerationOptions { IgnoreInaccessible = true, AttributesToSkip = FileAttributes.Hidden | FileAttributes.System }))
            {
                ct.ThrowIfCancellationRequested();
                var uri = SourceUris.FromLocalPath(e.FullName);
                if (e is DirectoryInfo d) items.Add(FolderItem(uri, d.Name, new DateTimeOffset(d.LastWriteTimeUtc)));
                else if (e is FileInfo f)
                {
                    var item = FileItem(uri, f.Name, f.Length, new DateTimeOffset(f.LastWriteTimeUtc));
                    if (item.Track is not null) item.Track.FilePath = f.FullName;
                    if (item.Track is not null) item.Track.Folder = f.DirectoryName;
                    items.Add(item);
                }
            }
        }
        catch (UnauthorizedAccessException ex) { throw new SourceException($"Access denied: {dir}", ex); }
        catch (IOException ex) { throw new SourceException(ex.Message, ex); }
        return Sort(items);
    }

    protected Task<IReadOnlyList<SourceItem>> SearchDirectoryAsync(IEnumerable<string> roots, string query, CancellationToken ct) => Task.Run<IReadOnlyList<SourceItem>>(() =>
    {
        var terms = query.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var results = new List<SourceItem>();
        foreach (var root in roots)
        {
            if (!Directory.Exists(root)) continue;
            foreach (var f in new DirectoryInfo(root).EnumerateFiles("*", new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true, MaxRecursionDepth = 12 }))
            {
                ct.ThrowIfCancellationRequested();
                if (!AudioFormats.IsAudioFile(f.Name)) continue;
                var rel = Path.GetRelativePath(root, f.FullName);
                if (!terms.All(t => rel.Contains(t, StringComparison.CurrentCultureIgnoreCase))) continue;
                var item = FileItem(SourceUris.FromLocalPath(f.FullName), f.Name, f.Length, new DateTimeOffset(f.LastWriteTimeUtc));
                item.Track!.FilePath = f.FullName;
                item.Track.Folder = f.DirectoryName;
                results.Add(item);
                if (results.Count >= 500) return results;
            }
        }
        return results;
    }, ct);

    public override Task<MediaLocation> ResolveAsync(string uri, CancellationToken ct = default)
    {
        var path = PathOf(uri);
        if (!File.Exists(path)) throw new SourceException($"File not found: {path}");
        return Task.FromResult(MediaLocation.ForFile(path));
    }

    public override Task<Track?> GetTrackAsync(string uri, CancellationToken ct = default)
    {
        var path = PathOf(uri);
        var fi = new FileInfo(path);
        if (!fi.Exists) return Task.FromResult<Track?>(null);
        var t = CreateFileTrack(uri, fi.Name, fi.Length, new DateTimeOffset(fi.LastWriteTimeUtc));
        t.FilePath = fi.FullName;
        t.Folder = fi.DirectoryName;
        t.IsRemote = false;
        return Task.FromResult<Track?>(t);
    }

    public override Task<string> CreateFolderAsync(string parentUri, string name, CancellationToken ct = default)
    {
        var dir = Path.Combine(PathOf(parentUri), SanitizeName(name));
        Directory.CreateDirectory(dir);
        return Task.FromResult(SourceUris.FromLocalPath(dir));
    }

    public override Task<string> RenameAsync(string uri, string newName, CancellationToken ct = default)
    {
        var path = PathOf(uri);
        var target = Path.Combine(Path.GetDirectoryName(path)!, SanitizeName(newName));
        if (Directory.Exists(path)) Directory.Move(path, target);
        else File.Move(path, target);
        return Task.FromResult(SourceUris.FromLocalPath(target));
    }

    public override Task DeleteAsync(string uri, CancellationToken ct = default)
    {
        var path = PathOf(uri);
        if (Directory.Exists(path)) Directory.Delete(path, recursive: true);
        else if (File.Exists(path)) File.Delete(path);
        return Task.CompletedTask;
    }

    public override async Task<string> UploadAsync(string folderUri, string fileName, Stream content, long length, IProgress<long>? progress = null, CancellationToken ct = default)
    {
        var target = Path.Combine(PathOf(folderUri), SanitizeName(fileName));
        var tmp = target + ".part";
        await using (var fs = new FileStream(tmp, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16, true))
            await StreamUtil.CopyWithProgressAsync(content, fs, progress, ct).ConfigureAwait(false);
        File.Move(tmp, target, overwrite: true);
        return SourceUris.FromLocalPath(target);
    }

    internal static string SanitizeName(string name)
    {
        var invalid = Path.GetInvalidFileNameChars();
        var s = new string(name.Select(c => invalid.Contains(c) ? '_' : c).ToArray()).Trim().TrimEnd('.');
        return s.Length == 0 ? "_" : s;
    }
}

/// <summary>
/// Local disk source. With an empty path the root lists the library's watched folders and all removable drives.
/// </summary>
public sealed class LocalSource(SourceConfig config, Settings.ISettingsService settings) : FileSystemSourceBase(config)
{
    public const string RootPseudoUri = "file:///";

    public override string RootUri => Config.Get(SourceKeys.Path) is { } p ? SourceUris.FromLocalPath(p) : RootPseudoUri;

    public override bool Owns(string uri) => SourceUris.SchemeOf(uri) == SourceUris.File &&
        (Config.Get(SourceKeys.Path) is not { } p || (SourceUris.TryGetLocalPath(uri, out var lp) && lp.StartsWith(Path.GetFullPath(p), StringComparison.OrdinalIgnoreCase)));

    public override Task TestConnectionAsync(CancellationToken ct = default)
    {
        if (Config.Get(SourceKeys.Path) is { } p && !Directory.Exists(p)) throw new SourceException($"Folder not found: {p}");
        return Task.CompletedTask;
    }

    public override Task<IReadOnlyList<SourceItem>> ListAsync(string? folderUri = null, CancellationToken ct = default)
    {
        if (folderUri is null && Config.Get(SourceKeys.Path) is null || folderUri == RootPseudoUri)
            return Task.FromResult(ListRoots());
        var uri = folderUri ?? RootUri;
        return Task.Run(() => ListDirectory(PathOf(uri), ct), ct);
    }

    private IReadOnlyList<SourceItem> ListRoots()
    {
        var items = new List<SourceItem>();
        foreach (var folder in settings.Current.WatchedFolders.Where(Directory.Exists))
            items.Add(FolderItem(SourceUris.FromLocalPath(folder), folder, subtitle: "Library folder"));
        foreach (var drive in RemovableDrives.GetReadyDrives())
            items.Add(FolderItem(SourceUris.FromLocalPath(drive.RootDirectory.FullName),
                string.IsNullOrWhiteSpace(drive.VolumeLabel) ? drive.Name : $"{drive.VolumeLabel} ({drive.Name.TrimEnd('\\')})",
                subtitle: drive.DriveType == DriveType.Removable ? "Removable drive" : drive.DriveType.ToString()));
        return items;
    }

    public override Task<IReadOnlyList<SourceItem>> SearchAsync(string query, CancellationToken ct = default)
    {
        var roots = Config.Get(SourceKeys.Path) is { } p ? new[] { p } : settings.Current.WatchedFolders.ToArray();
        return SearchDirectoryAsync(roots, query, ct);
    }
}

/// <summary>Enumerates removable drives (USB sticks, SD cards, optical) and raises an event when the set changes.</summary>
public sealed class RemovableDrives : IDisposable
{
    private readonly Timer _timer;
    private string _signature = "";

    public RemovableDrives()
    {
        _signature = Signature();
        _timer = new Timer(_ => Poll(), null, TimeSpan.FromSeconds(3), TimeSpan.FromSeconds(3));
    }

    /// <summary>Raised on a thread-pool thread when a removable drive is inserted or removed.</summary>
    public event EventHandler? DrivesChanged;

    public static IReadOnlyList<DriveInfo> GetReadyDrives()
    {
        var list = new List<DriveInfo>();
        foreach (var d in DriveInfo.GetDrives())
        {
            try
            {
                if (d.IsReady && d.DriveType is DriveType.Removable or DriveType.CDRom) list.Add(d);
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        return list;
    }

    private static string Signature() => string.Join('|', GetReadyDrives().Select(d => d.Name + d.VolumeLabel));

    private void Poll()
    {
        var sig = Signature();
        if (sig == _signature) return;
        _signature = sig;
        DrivesChanged?.Invoke(this, EventArgs.Empty);
    }

    public void Dispose() => _timer.Dispose();
}
