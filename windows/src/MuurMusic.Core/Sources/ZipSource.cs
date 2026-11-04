using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using MuurMusic.Core.Models;

namespace MuurMusic.Core.Sources;

/// <summary>Resolves any source URI to a readable location (implemented by <see cref="SourceManager"/>).</summary>
public interface ISourceResolver
{
    Task<MediaLocation> ResolveAsync(string uri, CancellationToken ct = default);
}

/// <summary>
/// Browses and plays audio inside a ZIP archive located on any source. Remote archives are downloaded once to the archive cache;
/// played entries are extracted next to it. URIs: <c>zip://&lt;archive source URI&gt;!/&lt;entry path&gt;</c>.
/// </summary>
public sealed class ZipSource(SourceConfig config, SourceContext ctx, ISourceResolver resolver) : MusicSourceBase(config)
{
    private readonly SemaphoreSlim _lock = new(1, 1);
    private string? _archivePath;
    private List<(string FullName, long Length, DateTimeOffset Modified)>? _entries;

    private string ArchiveUri => Config.Get(SourceKeys.ArchiveUri) ?? throw new SourceException("Archive location is not set.");
    private string CacheKey => Convert.ToHexStringLower(SHA1.HashData(Encoding.UTF8.GetBytes(ArchiveUri)));

    public override SourceCapabilities Capabilities => SourceCapabilities.Browse | SourceCapabilities.Search;
    public override string RootUri => SourceUris.ForZip(ArchiveUri, "");
    public override bool Owns(string uri) => SourceUris.TryParseZip(uri, out var archive, out _) && archive == ArchiveUri;

    private async Task<string> ArchivePathAsync(CancellationToken ct)
    {
        if (_archivePath is not null && File.Exists(_archivePath)) return _archivePath;
        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (_archivePath is not null && File.Exists(_archivePath)) return _archivePath;
            if (SourceUris.TryGetLocalPath(ArchiveUri, out var local) && File.Exists(local)) return _archivePath = local;
            var loc = await resolver.ResolveAsync(ArchiveUri, ct).ConfigureAwait(false);
            if (loc.Kind == MediaLocationKind.File) return _archivePath = loc.Path!;
            var target = Path.Combine(ctx.Paths.ArchiveCacheDirectory, CacheKey + ".zip");
            if (File.Exists(target) && (loc.Length < 0 || new FileInfo(target).Length == loc.Length)) return _archivePath = target;
            var tmp = target + ".part";
            await using (var src = await loc.OpenReadAsync(ctx.Http, 0, ct).ConfigureAwait(false))
            await using (var dst = new FileStream(tmp, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16, true))
                await src.CopyToAsync(dst, ct).ConfigureAwait(false);
            File.Move(tmp, target, true);
            return _archivePath = target;
        }
        finally { _lock.Release(); }
    }

    private async Task<List<(string FullName, long Length, DateTimeOffset Modified)>> EntriesAsync(CancellationToken ct)
    {
        if (_entries is not null) return _entries;
        var path = await ArchivePathAsync(ct).ConfigureAwait(false);
        return _entries = await Task.Run(() =>
        {
            try
            {
                using var zip = ZipFile.OpenRead(path);
                return zip.Entries.Select(e => (e.FullName.Replace('\\', '/'), e.Length, e.LastWriteTime)).ToList();
            }
            catch (InvalidDataException ex) { throw new SourceException($"Not a valid ZIP archive: {ex.Message}", ex); }
        }, ct).ConfigureAwait(false);
    }

    public override async Task TestConnectionAsync(CancellationToken ct = default) => await EntriesAsync(ct).ConfigureAwait(false);

    public override async Task<IReadOnlyList<SourceItem>> ListAsync(string? folderUri = null, CancellationToken ct = default)
    {
        var prefix = "";
        if (folderUri is not null && SourceUris.TryParseZip(folderUri, out _, out var entry)) prefix = entry.Trim('/');
        if (prefix.Length > 0) prefix += "/";
        var entries = await EntriesAsync(ct).ConfigureAwait(false);
        var folders = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var items = new List<SourceItem>();
        foreach (var (full, length, modified) in entries)
        {
            if (!full.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) || full.Length == prefix.Length) continue;
            var rest = full[prefix.Length..];
            var slash = rest.IndexOf('/');
            if (slash >= 0)
            {
                var folder = rest[..slash];
                if (folders.Add(folder)) items.Add(FolderItem(SourceUris.ForZip(ArchiveUri, prefix + folder + "/"), folder));
            }
            else items.Add(FileItem(SourceUris.ForZip(ArchiveUri, full), rest, length, modified));
        }
        return Sort(items);
    }

    public override async Task<IReadOnlyList<SourceItem>> SearchAsync(string query, CancellationToken ct = default)
    {
        var entries = await EntriesAsync(ct).ConfigureAwait(false);
        return entries.Where(e => AudioFormats.IsAudioFile(e.FullName) && e.FullName.Contains(query, StringComparison.CurrentCultureIgnoreCase))
            .Select(e => FileItem(SourceUris.ForZip(ArchiveUri, e.FullName), Path.GetFileName(e.FullName), e.Length, e.Modified)).ToList();
    }

    public override async Task<Track?> GetTrackAsync(string uri, CancellationToken ct = default)
    {
        if (!SourceUris.TryParseZip(uri, out _, out var entry)) return null;
        var e = (await EntriesAsync(ct).ConfigureAwait(false)).FirstOrDefault(x => x.FullName.Equals(entry, StringComparison.OrdinalIgnoreCase));
        return e.FullName is null ? null : CreateFileTrack(uri, Path.GetFileName(e.FullName), e.Length, e.Modified);
    }

    /// <summary>Extracts an entry (if needed) and returns the extracted file path.</summary>
    public async Task<string> ExtractAsync(string uri, CancellationToken ct = default)
    {
        if (!SourceUris.TryParseZip(uri, out _, out var entryPath)) throw new SourceException($"Invalid ZIP URI {uri}");
        var archive = await ArchivePathAsync(ct).ConfigureAwait(false);
        var safe = string.Join(Path.DirectorySeparatorChar, entryPath.Split('/', StringSplitOptions.RemoveEmptyEntries).Select(FileSystemSourceBase.SanitizeName));
        var target = Path.Combine(ctx.Paths.ArchiveCacheDirectory, CacheKey, safe);
        return await Task.Run(() =>
        {
            using var zip = ZipFile.OpenRead(archive);
            var entry = zip.Entries.FirstOrDefault(e => e.FullName.Replace('\\', '/').Equals(entryPath, StringComparison.OrdinalIgnoreCase))
                ?? throw new SourceException($"Entry not found in archive: {entryPath}");
            if (File.Exists(target) && new FileInfo(target).Length == entry.Length) return target;
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            var tmp = target + ".part";
            entry.ExtractToFile(tmp, true);
            File.Move(tmp, target, true);
            return target;
        }, ct).ConfigureAwait(false);
    }

    public override async Task<MediaLocation> ResolveAsync(string uri, CancellationToken ct = default) =>
        MediaLocation.ForFile(await ExtractAsync(uri, ct).ConfigureAwait(false), cachedCopy: true);
}
