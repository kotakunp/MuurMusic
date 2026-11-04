using System.Net;
using FluentFTP;
using Microsoft.Extensions.Logging;
using MuurMusic.Core.Models;

namespace MuurMusic.Core.Sources;

/// <summary>FTP / FTPS (explicit or implicit TLS) source using FluentFTP. URIs: <c>ftp(s)://host[:port]/path</c>.</summary>
public sealed class FtpSource(SourceConfig config, SourceContext ctx) : MusicSourceBase(config)
{
    private readonly ILogger _log = ctx.LoggerFactory.CreateLogger<FtpSource>();
    private readonly SemaphoreSlim _lock = new(1, 1);
    private AsyncFtpClient? _client;

    private string Host => Config.Get(SourceKeys.Host) ?? throw new SourceException("FTP host is not set.");
    private bool Secure => Config.GetBool(SourceKeys.UseTls) || Config.GetBool(SourceKeys.ImplicitTls);
    private int Port => Config.GetInt(SourceKeys.Port, Config.GetBool(SourceKeys.ImplicitTls) ? 990 : 21);
    private string Scheme => Secure ? SourceUris.Ftps : SourceUris.Ftp;
    private int? UriPort => Port is 21 or 990 ? null : Port;

    public override SourceCapabilities Capabilities => SourceCapabilities.Browse | SourceCapabilities.Write;
    public override string RootUri => SourceUris.ForHost(Scheme, Host, UriPort, Config.Get(SourceKeys.Path) ?? "/");

    public override bool Owns(string uri) =>
        SourceUris.TryParseHost(uri, out var scheme, out var host, out var port, out _) &&
        scheme is SourceUris.Ftp or SourceUris.Ftps && host.Equals(Host, StringComparison.OrdinalIgnoreCase) && (port ?? (scheme == SourceUris.Ftps && Config.GetBool(SourceKeys.ImplicitTls) ? 990 : 21)) == Port;

    private string PathOf(string uri) => SourceUris.TryParseHost(uri, out _, out _, out _, out var p) ? p : "/";
    private string UriOf(string path) => SourceUris.ForHost(Scheme, Host, UriPort, path);

    private async Task<AsyncFtpClient> CreateClientAsync(CancellationToken ct)
    {
        var password = await ctx.SecretAsync(Config, SourceKeys.SecretPassword, ct).ConfigureAwait(false);
        var cfg = new FtpConfig
        {
            EncryptionMode = Config.GetBool(SourceKeys.ImplicitTls) ? FtpEncryptionMode.Implicit : Config.GetBool(SourceKeys.UseTls) ? FtpEncryptionMode.Explicit : FtpEncryptionMode.None,
            ValidateAnyCertificate = Config.GetBool(SourceKeys.AcceptAnyCertificate),
            DataConnectionType = FtpDataConnectionType.AutoPassive,
            ConnectTimeout = 15000
        };
        var user = Config.Get(SourceKeys.Username) ?? "anonymous";
        var client = new AsyncFtpClient(Host, new NetworkCredential(user, password ?? (user == "anonymous" ? "muur@" : "")), Port, cfg);
        try
        {
            await client.Connect(ct).ConfigureAwait(false);
        }
        catch (FluentFTP.Exceptions.FtpAuthenticationException ex)
        {
            client.Dispose();
            throw new SourceAuthenticationException($"FTP login failed: {ex.Message}", ex);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            client.Dispose();
            throw new SourceException($"Cannot connect to {Host}: {ex.Message}", ex);
        }
        return client;
    }

    private async Task<T> WithClientAsync<T>(Func<AsyncFtpClient, Task<T>> action, CancellationToken ct)
    {
        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            for (var attempt = 0; ; attempt++)
            {
                if (_client is not { IsConnected: true })
                {
                    _client?.Dispose();
                    _client = await CreateClientAsync(ct).ConfigureAwait(false);
                }
                try { return await action(_client).ConfigureAwait(false); }
                catch (Exception ex) when (attempt == 0 && ex is IOException or TimeoutException or System.Net.Sockets.SocketException)
                {
                    _log.LogInformation(ex, "FTP connection dropped, reconnecting");
                    _client.Dispose();
                    _client = null;
                }
                catch (FluentFTP.Exceptions.FtpCommandException ex)
                {
                    throw new SourceException($"FTP error: {ex.Message}", ex);
                }
            }
        }
        finally { _lock.Release(); }
    }

    public override async Task TestConnectionAsync(CancellationToken ct = default) => await ListAsync(null, ct).ConfigureAwait(false);

    public override Task<IReadOnlyList<SourceItem>> ListAsync(string? folderUri = null, CancellationToken ct = default) =>
        WithClientAsync<IReadOnlyList<SourceItem>>(async c =>
        {
            var path = PathOf(folderUri ?? RootUri);
            var listing = await c.GetListing(path, FtpListOption.Modify | FtpListOption.Size, ct).ConfigureAwait(false);
            var items = new List<SourceItem>();
            foreach (var e in listing)
            {
                if (e.Name is "." or "..") continue;
                var full = e.FullName.StartsWith('/') ? e.FullName : path.TrimEnd('/') + "/" + e.Name;
                var mod = e.Modified == DateTime.MinValue ? (DateTimeOffset?)null : new DateTimeOffset(DateTime.SpecifyKind(e.Modified, DateTimeKind.Utc));
                if (e.Type == FtpObjectType.Directory) items.Add(FolderItem(UriOf(full), e.Name, mod));
                else if (e.Type == FtpObjectType.File) items.Add(FileItem(UriOf(full), e.Name, e.Size, mod));
            }
            return Sort(items);
        }, ct);

    public override async Task<MediaLocation> ResolveAsync(string uri, CancellationToken ct = default)
    {
        var path = PathOf(uri);
        var size = await WithClientAsync(c => c.GetFileSize(path, -1, ct), ct).ConfigureAwait(false);
        if (size < 0) throw new SourceException($"File not found: {path}");
        return MediaLocation.ForStream(async (offset, token) =>
        {
            // Each open stream gets a dedicated connection because FTP allows one data transfer per control connection.
            var client = await CreateClientAsync(token).ConfigureAwait(false);
            var stream = await client.OpenRead(path, FtpDataType.Binary, offset, size, token).ConfigureAwait(false);
            return new OwnedStream(stream, client);
        }, size, System.IO.Path.GetFileName(path));
    }

    public override async Task<Track?> GetTrackAsync(string uri, CancellationToken ct = default)
    {
        var path = PathOf(uri);
        var info = await WithClientAsync(c => c.GetObjectInfo(path, true, ct), ct).ConfigureAwait(false);
        if (info is null) return null;
        return CreateFileTrack(uri, info.Name, info.Size, info.Modified == DateTime.MinValue ? null : new DateTimeOffset(DateTime.SpecifyKind(info.Modified, DateTimeKind.Utc)));
    }

    public override Task<string> CreateFolderAsync(string parentUri, string name, CancellationToken ct = default) =>
        WithClientAsync(async c =>
        {
            var path = PathOf(parentUri).TrimEnd('/') + "/" + FileSystemSourceBase.SanitizeName(name);
            await c.CreateDirectory(path, true, ct).ConfigureAwait(false);
            return UriOf(path);
        }, ct);

    public override Task<string> RenameAsync(string uri, string newName, CancellationToken ct = default) =>
        WithClientAsync(async c =>
        {
            var path = PathOf(uri);
            var target = path[..(path.TrimEnd('/').LastIndexOf('/') + 1)] + FileSystemSourceBase.SanitizeName(newName);
            await c.Rename(path, target, ct).ConfigureAwait(false);
            return UriOf(target);
        }, ct);

    public override Task DeleteAsync(string uri, CancellationToken ct = default) =>
        WithClientAsync(async c =>
        {
            var path = PathOf(uri);
            if (await c.DirectoryExists(path, ct).ConfigureAwait(false)) await c.DeleteDirectory(path, ct).ConfigureAwait(false);
            else await c.DeleteFile(path, ct).ConfigureAwait(false);
            return 0;
        }, ct);

    public override Task<string> UploadAsync(string folderUri, string fileName, Stream content, long length, IProgress<long>? progress = null, CancellationToken ct = default) =>
        WithClientAsync(async c =>
        {
            var path = PathOf(folderUri).TrimEnd('/') + "/" + FileSystemSourceBase.SanitizeName(fileName);
            var p = progress is null ? null : new Progress<FtpProgress>(x => progress.Report(x.TransferredBytes));
            var status = await c.UploadStream(content, path, FtpRemoteExists.Overwrite, true, p, ct).ConfigureAwait(false);
            if (status == FtpStatus.Failed) throw new SourceException($"Upload of {fileName} failed.");
            return UriOf(path);
        }, ct);

    public override async ValueTask DisposeAsync()
    {
        if (_client is not null)
        {
            try { await _client.Disconnect().ConfigureAwait(false); } catch (Exception) { }
            _client.Dispose();
            _client = null;
        }
        await base.DisposeAsync().ConfigureAwait(false);
    }
}

/// <summary>Stream wrapper that disposes an extra owner object (connection) together with the stream.</summary>
internal sealed class OwnedStream(Stream inner, IDisposable owner) : Stream
{
    public override bool CanRead => inner.CanRead;
    public override bool CanSeek => inner.CanSeek;
    public override bool CanWrite => false;
    public override long Length => inner.Length;
    public override long Position { get => inner.Position; set => inner.Position = value; }
    public override void Flush() { }
    public override int Read(byte[] buffer, int offset, int count) => inner.Read(buffer, offset, count);
    public override int Read(Span<byte> buffer) => inner.Read(buffer);
    public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default) => inner.ReadAsync(buffer, ct);
    public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken ct) => inner.ReadAsync(buffer, offset, count, ct);
    public override long Seek(long offset, SeekOrigin origin) => inner.Seek(offset, origin);
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            try { inner.Dispose(); } catch (Exception) { }
            owner.Dispose();
        }
        base.Dispose(disposing);
    }
}
