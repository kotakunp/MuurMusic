using System.Text;
using Microsoft.Extensions.Logging;
using MuurMusic.Core.Models;
using Renci.SshNet;
using Renci.SshNet.Common;

namespace MuurMusic.Core.Sources;

/// <summary>SFTP source (password or private key auth) using SSH.NET. URIs: <c>sftp://host[:port]/path</c>.</summary>
public sealed class SftpSource(SourceConfig config, SourceContext ctx) : MusicSourceBase(config)
{
    private readonly ILogger _log = ctx.LoggerFactory.CreateLogger<SftpSource>();
    private readonly SemaphoreSlim _connectLock = new(1, 1);
    private SftpClient? _client;

    private string Host => Config.Get(SourceKeys.Host) ?? throw new SourceException("SFTP host is not set.");
    private int Port => Config.GetInt(SourceKeys.Port, 22);
    private int? UriPort => Port == 22 ? null : Port;

    public override SourceCapabilities Capabilities => SourceCapabilities.Browse | SourceCapabilities.Write;
    public override string RootUri => SourceUris.ForHost(SourceUris.Sftp, Host, UriPort, Config.Get(SourceKeys.Path) ?? "/");

    public override bool Owns(string uri) =>
        SourceUris.TryParseHost(uri, out var scheme, out var host, out var port, out _) &&
        scheme == SourceUris.Sftp && host.Equals(Host, StringComparison.OrdinalIgnoreCase) && (port ?? 22) == Port;

    private static string PathOf(string uri) => SourceUris.TryParseHost(uri, out _, out _, out _, out var p) ? p : "/";
    private string UriOf(string path) => SourceUris.ForHost(SourceUris.Sftp, Host, UriPort, path);

    private async Task<SftpClient> ClientAsync(CancellationToken ct)
    {
        if (_client is { IsConnected: true }) return _client;
        await _connectLock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (_client is { IsConnected: true }) return _client;
            _client?.Dispose();
            var user = Config.Get(SourceKeys.Username) ?? throw new SourceException("SFTP username is not set.");
            var key = await ctx.SecretAsync(Config, SourceKeys.SecretPrivateKey, ct).ConfigureAwait(false);
            SftpClient client;
            if (!string.IsNullOrWhiteSpace(key))
            {
                var passphrase = await ctx.SecretAsync(Config, SourceKeys.SecretPassphrase, ct).ConfigureAwait(false);
                var keyFile = new PrivateKeyFile(new MemoryStream(Encoding.UTF8.GetBytes(key)), string.IsNullOrEmpty(passphrase) ? null : passphrase);
                client = new SftpClient(Host, Port, user, new IPrivateKeySource[] { keyFile });
            }
            else
            {
                var password = await ctx.SecretAsync(Config, SourceKeys.SecretPassword, ct).ConfigureAwait(false) ?? "";
                client = new SftpClient(Host, Port, user, password);
            }
            client.OperationTimeout = TimeSpan.FromSeconds(30);
            try
            {
                await client.ConnectAsync(ct).ConfigureAwait(false);
            }
            catch (SshAuthenticationException ex)
            {
                client.Dispose();
                throw new SourceAuthenticationException($"SFTP login failed: {ex.Message}", ex);
            }
            catch (Exception ex) when (ex is SshException or System.Net.Sockets.SocketException or SshConnectionException)
            {
                client.Dispose();
                throw new SourceException($"Cannot connect to {Host}: {ex.Message}", ex);
            }
            _client = client;
            return client;
        }
        finally { _connectLock.Release(); }
    }

    private async Task<T> RunAsync<T>(Func<SftpClient, Task<T>> action, CancellationToken ct)
    {
        for (var attempt = 0; ; attempt++)
        {
            var c = await ClientAsync(ct).ConfigureAwait(false);
            try { return await action(c).ConfigureAwait(false); }
            catch (SftpPathNotFoundException ex) { throw new SourceException($"Not found: {ex.Message}", ex); }
            catch (SftpPermissionDeniedException ex) { throw new SourceException($"Permission denied: {ex.Message}", ex); }
            catch (Exception ex) when (attempt == 0 && ex is SshConnectionException or ObjectDisposedException or System.Net.Sockets.SocketException)
            {
                _log.LogInformation(ex, "SFTP connection dropped, reconnecting");
                c.Dispose();
                _client = null;
            }
        }
    }

    public override async Task TestConnectionAsync(CancellationToken ct = default) => await ListAsync(null, ct).ConfigureAwait(false);

    public override Task<IReadOnlyList<SourceItem>> ListAsync(string? folderUri = null, CancellationToken ct = default) =>
        RunAsync<IReadOnlyList<SourceItem>>(async c =>
        {
            var items = new List<SourceItem>();
            await foreach (var f in c.ListDirectoryAsync(PathOf(folderUri ?? RootUri), ct).ConfigureAwait(false))
            {
                if (f.Name is "." or ".." || f.Name.StartsWith('.')) continue;
                var mod = new DateTimeOffset(DateTime.SpecifyKind(f.LastWriteTimeUtc, DateTimeKind.Utc));
                if (f.IsDirectory) items.Add(FolderItem(UriOf(f.FullName), f.Name, mod));
                else if (f.IsRegularFile) items.Add(FileItem(UriOf(f.FullName), f.Name, f.Length, mod));
            }
            return Sort(items);
        }, ct);

    public override async Task<MediaLocation> ResolveAsync(string uri, CancellationToken ct = default)
    {
        var path = PathOf(uri);
        var attrs = await RunAsync(c => c.GetAttributesAsync(path, ct), ct).ConfigureAwait(false);
        return MediaLocation.ForStream(async (offset, token) =>
        {
            var c = await ClientAsync(token).ConfigureAwait(false);
            var s = await c.OpenAsync(path, FileMode.Open, FileAccess.Read, token).ConfigureAwait(false);
            if (offset > 0) s.Seek(offset, SeekOrigin.Begin);
            return s;
        }, attrs.Size, System.IO.Path.GetFileName(path));
    }

    public override async Task<Track?> GetTrackAsync(string uri, CancellationToken ct = default)
    {
        var path = PathOf(uri);
        var attrs = await RunAsync(c => c.GetAttributesAsync(path, ct), ct).ConfigureAwait(false);
        return CreateFileTrack(uri, System.IO.Path.GetFileName(path), attrs.Size, new DateTimeOffset(DateTime.SpecifyKind(attrs.LastWriteTimeUtc, DateTimeKind.Utc)));
    }

    public override Task<string> CreateFolderAsync(string parentUri, string name, CancellationToken ct = default) =>
        RunAsync(async c =>
        {
            var path = PathOf(parentUri).TrimEnd('/') + "/" + FileSystemSourceBase.SanitizeName(name);
            await c.CreateDirectoryAsync(path, ct).ConfigureAwait(false);
            return UriOf(path);
        }, ct);

    public override Task<string> RenameAsync(string uri, string newName, CancellationToken ct = default) =>
        RunAsync(async c =>
        {
            var path = PathOf(uri);
            var target = path[..(path.TrimEnd('/').LastIndexOf('/') + 1)] + FileSystemSourceBase.SanitizeName(newName);
            await c.RenameFileAsync(path, target, ct).ConfigureAwait(false);
            return UriOf(target);
        }, ct);

    public override Task DeleteAsync(string uri, CancellationToken ct = default) =>
        RunAsync(async c =>
        {
            await DeleteRecursiveAsync(c, PathOf(uri), ct).ConfigureAwait(false);
            return 0;
        }, ct);

    private static async Task DeleteRecursiveAsync(SftpClient c, string path, CancellationToken ct)
    {
        var attrs = await c.GetAttributesAsync(path, ct).ConfigureAwait(false);
        if (!attrs.IsDirectory)
        {
            await c.DeleteFileAsync(path, ct).ConfigureAwait(false);
            return;
        }
        var children = new List<string>();
        await foreach (var f in c.ListDirectoryAsync(path, ct).ConfigureAwait(false))
            if (f.Name is not "." and not "..") children.Add(f.FullName);
        foreach (var child in children) await DeleteRecursiveAsync(c, child, ct).ConfigureAwait(false);
        await c.DeleteDirectoryAsync(path, ct).ConfigureAwait(false);
    }

    public override Task<string> UploadAsync(string folderUri, string fileName, Stream content, long length, IProgress<long>? progress = null, CancellationToken ct = default) =>
        RunAsync(async c =>
        {
            var path = PathOf(folderUri).TrimEnd('/') + "/" + FileSystemSourceBase.SanitizeName(fileName);
            var p = progress is null ? null : new Progress<UploadFileProgressReport>(x => progress.Report((long)x.TotalBytesUploaded));
            await c.UploadFileAsync(content, path, true, p, ct).ConfigureAwait(false);
            return UriOf(path);
        }, ct);

    public override async ValueTask DisposeAsync()
    {
        if (_client is not null)
        {
            try { _client.Disconnect(); } catch (Exception) { }
            _client.Dispose();
            _client = null;
        }
        await base.DisposeAsync().ConfigureAwait(false);
    }
}
