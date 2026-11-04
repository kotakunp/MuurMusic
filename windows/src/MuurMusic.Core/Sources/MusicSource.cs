using System.Net.Http.Headers;
using MuurMusic.Core.Models;

namespace MuurMusic.Core.Sources;

/// <summary>Operations a source supports. The UI should only offer actions whose flag is present.</summary>
[Flags]
public enum SourceCapabilities
{
    None = 0,
    Browse = 1,
    Search = 2,
    CreateFolder = 4,
    Rename = 8,
    Delete = 16,
    Upload = 32,
    /// <summary>Source exposes artist/album/genre views (media servers).</summary>
    MediaLibrary = 64,
    Write = CreateFolder | Rename | Delete | Upload
}

public enum SourceItemKind { Folder, Audio, Playlist, Archive, Image, Other, Artist, Album, Genre, Library }

/// <summary>An entry returned when browsing a source.</summary>
public sealed record SourceItem
{
    /// <summary>Source URI of the entry; pass it back to <see cref="IMusicSource.ListAsync"/> or <see cref="IMusicSource.ResolveAsync"/>.</summary>
    public required string Uri { get; init; }
    public required string Name { get; init; }
    public SourceItemKind Kind { get; init; }
    public long Size { get; init; }
    public DateTimeOffset? Modified { get; init; }
    /// <summary>Metadata for audio entries (always set for <see cref="SourceItemKind.Audio"/>).</summary>
    public Track? Track { get; init; }
    public string? ArtworkUrl { get; init; }
    public string? Subtitle { get; init; }
    public int? ChildCount { get; init; }
    public bool IsFolder => Kind is SourceItemKind.Folder or SourceItemKind.Artist or SourceItemKind.Album or SourceItemKind.Genre or SourceItemKind.Library or SourceItemKind.Archive;
    public bool IsPlayable => Kind == SourceItemKind.Audio;
}

public enum MediaLocationKind { File, Url, Stream }

/// <summary>
/// Where the audio bytes of a source URI can be read: a local/UNC file, an HTTP(S) URL with optional headers,
/// or a random-access stream factory (FTP, SFTP, SMB via SMBLibrary, ZIP, digest-auth WebDAV).
/// </summary>
public sealed class MediaLocation
{
    private MediaLocation(MediaLocationKind kind) => Kind = kind;

    public MediaLocationKind Kind { get; }
    public string? Path { get; private init; }
    public string? Url { get; private init; }
    public IReadOnlyDictionary<string, string> Headers { get; private init; } = new Dictionary<string, string>();
    /// <summary>Opens a read stream starting at the given byte offset.</summary>
    public Func<long, CancellationToken, Task<Stream>>? OpenAt { get; private init; }
    /// <summary>Total length in bytes, or -1 when unknown.</summary>
    public long Length { get; init; } = -1;
    public string? MimeType { get; init; }
    public string FileName { get; init; } = "";
    /// <summary>True when the location points to a cached or offline copy rather than the original remote item.</summary>
    public bool IsCachedCopy { get; init; }

    public bool IsRemote => Kind != MediaLocationKind.File;

    public static MediaLocation ForFile(string path, bool cachedCopy = false)
    {
        long len = -1;
        try { len = new FileInfo(path).Length; } catch (IOException) { } catch (UnauthorizedAccessException) { }
        return new MediaLocation(MediaLocationKind.File)
        {
            Path = path, Length = len, FileName = System.IO.Path.GetFileName(path),
            MimeType = AudioFormats.MimeTypeFromExtension(path), IsCachedCopy = cachedCopy
        };
    }

    public static MediaLocation ForUrl(string url, IReadOnlyDictionary<string, string>? headers = null, long length = -1, string? fileName = null, string? mime = null) =>
        new(MediaLocationKind.Url)
        {
            Url = url, Headers = headers ?? new Dictionary<string, string>(), Length = length,
            FileName = fileName ?? SourceUris.FileNameOf(url), MimeType = mime ?? (fileName is null ? null : AudioFormats.MimeTypeFromExtension(fileName))
        };

    public static MediaLocation ForStream(Func<long, CancellationToken, Task<Stream>> openAt, long length, string fileName, string? mime = null) =>
        new(MediaLocationKind.Stream)
        {
            OpenAt = openAt, Length = length, FileName = fileName, MimeType = mime ?? AudioFormats.MimeTypeFromExtension(fileName)
        };

    /// <summary>Opens a read stream at <paramref name="offset"/> for any location kind (HTTP uses Range requests).</summary>
    public async Task<Stream> OpenReadAsync(HttpClient http, long offset = 0, CancellationToken ct = default)
    {
        switch (Kind)
        {
            case MediaLocationKind.File:
                var fs = new FileStream(Path!, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1 << 16, FileOptions.Asynchronous | FileOptions.SequentialScan);
                if (offset > 0) fs.Seek(offset, SeekOrigin.Begin);
                return fs;
            case MediaLocationKind.Stream:
                return await OpenAt!(offset, ct).ConfigureAwait(false);
            default:
                var req = new HttpRequestMessage(HttpMethod.Get, Url);
                foreach (var (k, v) in Headers) req.Headers.TryAddWithoutValidation(k, v);
                if (offset > 0) req.Headers.Range = new RangeHeaderValue(offset, null);
                var resp = await http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false);
                if (!resp.IsSuccessStatusCode)
                {
                    var code = (int)resp.StatusCode;
                    resp.Dispose();
                    throw new SourceException($"HTTP {code} while opening {FileName}");
                }
                var body = await resp.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
                if (offset > 0 && resp.StatusCode != System.Net.HttpStatusCode.PartialContent)
                {
                    // Server ignored the Range header: skip bytes manually.
                    await StreamUtil.SkipAsync(body, offset, ct).ConfigureAwait(false);
                }
                return new ResponseStream(body, resp);
        }
    }
}

/// <summary>Error raised by sources with a user-presentable message.</summary>
public class SourceException : Exception
{
    public SourceException(string message, Exception? inner = null) : base(message, inner) { }
}

/// <summary>Raised when a source needs (re)authentication, e.g. an expired OAuth refresh token or wrong password.</summary>
public sealed class SourceAuthenticationException(string message, Exception? inner = null) : SourceException(message, inner);

/// <summary>Raised when an OAuth provider has no client id in appsettings.json / appsettings.Local.json.</summary>
public sealed class OAuthNotConfiguredException(string provider)
    : SourceException($"{provider} is not configured: set \"OAuth:{provider}:ClientId\" in appsettings.json or appsettings.Local.json.")
{
    public string Provider { get; } = provider;
}

/// <summary>Raised when a remote item is requested while offline mode is on and no local copy exists.</summary>
public sealed class OfflineException(string uri) : SourceException("Offline mode is on and this item has no offline or cached copy.")
{
    public string Uri { get; } = uri;
}

/// <summary>A browsable/playable music source (local disk, network share, cloud drive or media server).</summary>
public interface IMusicSource : IAsyncDisposable
{
    SourceConfig Config { get; }
    SourceKind Kind { get; }
    SourceCapabilities Capabilities { get; }
    /// <summary>URI of the top-level folder; <see cref="ListAsync"/> with null lists it.</summary>
    string RootUri { get; }
    /// <summary>True when the URI belongs to this source.</summary>
    bool Owns(string uri);
    /// <summary>Connects and authenticates; throws <see cref="SourceException"/> with a readable message on failure.</summary>
    Task TestConnectionAsync(CancellationToken ct = default);
    /// <summary>Lists the children of a folder URI (null = root).</summary>
    Task<IReadOnlyList<SourceItem>> ListAsync(string? folderUri = null, CancellationToken ct = default);
    /// <summary>Resolves where the bytes of an audio item can be read.</summary>
    Task<MediaLocation> ResolveAsync(string uri, CancellationToken ct = default);
    /// <summary>Searches the source (requires <see cref="SourceCapabilities.Search"/>).</summary>
    Task<IReadOnlyList<SourceItem>> SearchAsync(string query, CancellationToken ct = default);
    /// <summary>Returns metadata for a single audio item, or null when it does not exist.</summary>
    Task<Track?> GetTrackAsync(string uri, CancellationToken ct = default);
    Task<string> CreateFolderAsync(string parentUri, string name, CancellationToken ct = default);
    Task<string> RenameAsync(string uri, string newName, CancellationToken ct = default);
    Task DeleteAsync(string uri, CancellationToken ct = default);
    /// <summary>Uploads a stream as a new file in a folder and returns its URI.</summary>
    Task<string> UploadAsync(string folderUri, string fileName, Stream content, long length, IProgress<long>? progress = null, CancellationToken ct = default);
}

/// <summary>Base class supplying shared helpers and NotSupported defaults for optional operations.</summary>
public abstract class MusicSourceBase(SourceConfig config) : IMusicSource
{
    public SourceConfig Config { get; } = config;
    public SourceKind Kind => Config.Kind;
    public abstract SourceCapabilities Capabilities { get; }
    public abstract string RootUri { get; }

    public virtual bool Owns(string uri) => uri.StartsWith(RootUri.TrimEnd('/'), StringComparison.OrdinalIgnoreCase);
    public abstract Task TestConnectionAsync(CancellationToken ct = default);
    public abstract Task<IReadOnlyList<SourceItem>> ListAsync(string? folderUri = null, CancellationToken ct = default);
    public abstract Task<MediaLocation> ResolveAsync(string uri, CancellationToken ct = default);

    public virtual Task<IReadOnlyList<SourceItem>> SearchAsync(string query, CancellationToken ct = default) =>
        throw new NotSupportedException($"{Kind} sources do not support search.");

    public virtual Task<Track?> GetTrackAsync(string uri, CancellationToken ct = default) =>
        Task.FromResult<Track?>(CreateFileTrack(uri, SourceUris.FileNameOf(uri), 0, null));

    public virtual Task<string> CreateFolderAsync(string parentUri, string name, CancellationToken ct = default) =>
        throw new NotSupportedException($"{Kind} sources are read-only.");
    public virtual Task<string> RenameAsync(string uri, string newName, CancellationToken ct = default) =>
        throw new NotSupportedException($"{Kind} sources are read-only.");
    public virtual Task DeleteAsync(string uri, CancellationToken ct = default) =>
        throw new NotSupportedException($"{Kind} sources are read-only.");
    public virtual Task<string> UploadAsync(string folderUri, string fileName, Stream content, long length, IProgress<long>? progress = null, CancellationToken ct = default) =>
        throw new NotSupportedException($"{Kind} sources are read-only.");

    public virtual ValueTask DisposeAsync()
    {
        GC.SuppressFinalize(this);
        return ValueTask.CompletedTask;
    }

    /// <summary>Builds a minimal track for a file-like item, deriving artist/title from "Artist - Title" file names.</summary>
    protected Track CreateFileTrack(string uri, string fileName, long size, DateTimeOffset? modified)
    {
        var t = new Track
        {
            SourceUri = uri,
            SourceId = Config.Id,
            FileName = fileName,
            FileSize = size,
            FileModifiedMs = modified?.ToUnixTimeMilliseconds() ?? 0,
            Format = System.IO.Path.GetExtension(fileName).TrimStart('.').ToLowerInvariant(),
            Codec = AudioFormats.CodecFromExtension(fileName),
            IsRemote = Kind != SourceKind.Local,
        };
        var stem = System.IO.Path.GetFileNameWithoutExtension(fileName);
        var dash = stem.IndexOf(" - ", StringComparison.Ordinal);
        if (dash > 0)
        {
            var left = stem[..dash].Trim();
            var right = stem[(dash + 3)..].Trim();
            if (int.TryParse(left, out var num)) { t.TrackNumber = num; t.Title = right; }
            else { t.Artist = left; t.Title = right; }
        }
        else t.Title = stem;
        return t;
    }

    protected static SourceItemKind KindForFile(string name)
    {
        if (AudioFormats.IsAudioFile(name)) return SourceItemKind.Audio;
        if (AudioFormats.IsPlaylistFile(name)) return SourceItemKind.Playlist;
        if (AudioFormats.IsArchiveFile(name)) return SourceItemKind.Archive;
        if (AudioFormats.ImageExtensions.Contains(System.IO.Path.GetExtension(name))) return SourceItemKind.Image;
        return SourceItemKind.Other;
    }

    /// <summary>Builds a SourceItem for a file entry from a host or path-based listing.</summary>
    protected SourceItem FileItem(string uri, string name, long size, DateTimeOffset? modified)
    {
        var kind = KindForFile(name);
        return new SourceItem
        {
            Uri = uri, Name = name, Kind = kind, Size = size, Modified = modified,
            Track = kind == SourceItemKind.Audio ? CreateFileTrack(uri, name, size, modified) : null
        };
    }

    protected static SourceItem FolderItem(string uri, string name, DateTimeOffset? modified = null, SourceItemKind kind = SourceItemKind.Folder, string? artworkUrl = null, string? subtitle = null, int? childCount = null) =>
        new() { Uri = uri, Name = name, Kind = kind, Modified = modified, ArtworkUrl = artworkUrl, Subtitle = subtitle, ChildCount = childCount };

    /// <summary>Folders first, then case-insensitive natural-ish name order.</summary>
    protected static IReadOnlyList<SourceItem> Sort(IEnumerable<SourceItem> items) =>
        items.OrderByDescending(i => i.IsFolder).ThenBy(i => i.Name, StringComparer.CurrentCultureIgnoreCase).ToList();
}

internal static class StreamUtil
{
    public static async Task SkipAsync(Stream s, long count, CancellationToken ct)
    {
        var buf = new byte[81920];
        while (count > 0)
        {
            var n = await s.ReadAsync(buf.AsMemory(0, (int)Math.Min(buf.Length, count)), ct).ConfigureAwait(false);
            if (n <= 0) throw new EndOfStreamException();
            count -= n;
        }
    }

    public static async Task CopyWithProgressAsync(Stream src, Stream dst, IProgress<long>? progress, CancellationToken ct, long already = 0)
    {
        var buf = new byte[1 << 17];
        long total = already;
        int n;
        while ((n = await src.ReadAsync(buf, ct).ConfigureAwait(false)) > 0)
        {
            await dst.WriteAsync(buf.AsMemory(0, n), ct).ConfigureAwait(false);
            total += n;
            progress?.Report(total);
        }
    }
}

/// <summary>Stream wrapper that disposes the owning HTTP response.</summary>
internal sealed class ResponseStream(Stream inner, IDisposable owner) : Stream
{
    public override bool CanRead => true;
    public override bool CanSeek => false;
    public override bool CanWrite => false;
    public override long Length => throw new NotSupportedException();
    public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
    public override void Flush() { }
    public override int Read(byte[] buffer, int offset, int count) => inner.Read(buffer, offset, count);
    public override int Read(Span<byte> buffer) => inner.Read(buffer);
    public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default) => inner.ReadAsync(buffer, ct);
    public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken ct) => inner.ReadAsync(buffer, offset, count, ct);
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    protected override void Dispose(bool disposing)
    {
        if (disposing) { inner.Dispose(); owner.Dispose(); }
        base.Dispose(disposing);
    }
}

/// <summary>
/// Seekable read-only stream over a "open at offset" factory. Seeking far away reopens the underlying stream;
/// short forward seeks are satisfied by skipping.
/// </summary>
public sealed class RandomAccessStream : Stream
{
    private readonly Func<long, CancellationToken, Task<Stream>> _open;
    private readonly long _length;
    private Stream? _inner;
    private long _innerPos;
    private long _pos;
    private const long SkipThreshold = 256 * 1024;

    public RandomAccessStream(Func<long, CancellationToken, Task<Stream>> open, long length)
    {
        _open = open;
        _length = length;
    }

    public override bool CanRead => true;
    public override bool CanSeek => _length >= 0;
    public override bool CanWrite => false;
    public override long Length => _length >= 0 ? _length : throw new NotSupportedException();
    public override long Position { get => _pos; set => Seek(value, SeekOrigin.Begin); }
    public override void Flush() { }

    public override int Read(byte[] buffer, int offset, int count) => Read(buffer.AsSpan(offset, count));

    public override int Read(Span<byte> buffer)
    {
        var arr = new byte[buffer.Length];
        var n = ReadAsync(arr.AsMemory(), CancellationToken.None).AsTask().GetAwaiter().GetResult();
        arr.AsSpan(0, n).CopyTo(buffer);
        return n;
    }

    public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default)
    {
        if (_length >= 0 && _pos >= _length) return 0;
        await EnsurePositionAsync(ct).ConfigureAwait(false);
        var n = await _inner!.ReadAsync(buffer, ct).ConfigureAwait(false);
        _pos += n;
        _innerPos += n;
        return n;
    }

    public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken ct) => ReadAsync(buffer.AsMemory(offset, count), ct).AsTask();

    private async Task EnsurePositionAsync(CancellationToken ct)
    {
        if (_inner is not null && _innerPos == _pos) return;
        if (_inner is not null && _pos > _innerPos && _pos - _innerPos <= SkipThreshold)
        {
            await StreamUtil.SkipAsync(_inner, _pos - _innerPos, ct).ConfigureAwait(false);
            _innerPos = _pos;
            return;
        }
        if (_inner is not null) await _inner.DisposeAsync().ConfigureAwait(false);
        _inner = await _open(_pos, ct).ConfigureAwait(false);
        _innerPos = _pos;
    }

    public override long Seek(long offset, SeekOrigin origin)
    {
        var target = origin switch
        {
            SeekOrigin.Begin => offset,
            SeekOrigin.Current => _pos + offset,
            SeekOrigin.End => (_length >= 0 ? _length : throw new NotSupportedException()) + offset,
            _ => throw new ArgumentOutOfRangeException(nameof(origin))
        };
        if (target < 0) throw new IOException("Seek before start of stream.");
        _pos = target;
        return _pos;
    }

    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();

    protected override void Dispose(bool disposing)
    {
        if (disposing) _inner?.Dispose();
        _inner = null;
        base.Dispose(disposing);
    }
}
