using System.Net;
using System.Runtime.InteropServices;
using Microsoft.Extensions.Logging;
using MuurMusic.Core.Models;
using SMBLibrary;
using SMBLibrary.Client;
using SmbFileAttributes = SMBLibrary.FileAttributes;

namespace MuurMusic.Core.Sources;

/// <summary>
/// SMB / Windows share source. "system" auth mode goes through the Windows redirector (UNC paths, current user's credentials);
/// "direct" mode talks SMB2/3 itself via SMBLibrary with stored credentials (works without mapping drives).
/// URIs are <c>smb://host/share/path</c> in both modes.
/// </summary>
public sealed class SmbSource : FileSystemSourceBase
{
    private readonly SourceContext _ctx;
    private readonly ILogger _log;
    private readonly SemaphoreSlim _lock = new(1, 1);
    private readonly Dictionary<string, ISMBFileStore> _stores = new(StringComparer.OrdinalIgnoreCase);
    private SMB2Client? _client;

    public SmbSource(SourceConfig config, SourceContext ctx) : base(config)
    {
        _ctx = ctx;
        _log = ctx.LoggerFactory.CreateLogger<SmbSource>();
    }

    private string Host => Config.Get(SourceKeys.Host) ?? throw new SourceException("SMB host is not set.");
    private string? Share => Config.Get(SourceKeys.Share)?.Trim('\\', '/');
    private string SubPath => (Config.Get(SourceKeys.Path) ?? "").Replace('\\', '/').Trim('/');
    public bool DirectMode => string.Equals(Config.Get(SourceKeys.AuthMode), "direct", StringComparison.OrdinalIgnoreCase)
        || (Config.Get(SourceKeys.AuthMode) is null && Config.Get(SourceKeys.Username) is not null);

    public override SourceCapabilities Capabilities => SourceCapabilities.Browse | SourceCapabilities.Write | (DirectMode ? 0 : SourceCapabilities.Search);

    public override string RootUri
    {
        get
        {
            var path = string.Join('/', new[] { Share, SubPath }.Where(s => !string.IsNullOrEmpty(s)));
            return "smb://" + Host + "/" + SourceUris.EscapePath(path);
        }
    }

    public override bool Owns(string uri) => SourceUris.SchemeOf(uri) == SourceUris.Smb &&
        uri.StartsWith("smb://" + Host + "/", StringComparison.OrdinalIgnoreCase) &&
        (Share is null || Split(uri).Share.Equals(Share, StringComparison.OrdinalIgnoreCase));

    private static (string Host, string Share, string Path) Split(string uri)
    {
        var rest = uri["smb://".Length..];
        var segs = rest.Split('/', StringSplitOptions.RemoveEmptyEntries).Select(Uri.UnescapeDataString).ToArray();
        return (segs.ElementAtOrDefault(0) ?? "", segs.ElementAtOrDefault(1) ?? "", string.Join('\\', segs.Skip(2)));
    }

    private string UriFor(string share, string path) =>
        "smb://" + Host + "/" + SourceUris.EscapePath((share + "/" + path.Replace('\\', '/')).Trim('/'));

    public override async Task TestConnectionAsync(CancellationToken ct = default)
    {
        if (DirectMode)
        {
            await ListAsync(null, ct).ConfigureAwait(false);
            return;
        }
        await Task.Run(() =>
        {
            if (Share is null) { NetShares.Enumerate(Host); return; }
            var unc = @"\\" + Host + @"\" + Share + (SubPath.Length > 0 ? @"\" + SubPath.Replace('/', '\\') : "");
            if (!Directory.Exists(unc)) throw new SourceException($"Cannot reach {unc}. Check the share name or use direct mode with a username.");
        }, ct).ConfigureAwait(false);
    }

    public override async Task<IReadOnlyList<SourceItem>> ListAsync(string? folderUri = null, CancellationToken ct = default)
    {
        var uri = folderUri ?? RootUri;
        var (_, share, path) = Split(uri);
        if (share.Length == 0)
        {
            var shares = DirectMode ? await ListSharesDirectAsync(ct).ConfigureAwait(false) : await Task.Run(() => NetShares.Enumerate(Host), ct).ConfigureAwait(false);
            return shares.Select(s => FolderItem(UriFor(s, ""), s, subtitle: "Share")).ToList();
        }
        if (!DirectMode)
            return await Task.Run(() => ListDirectory(PathOf(uri), ct), ct).ConfigureAwait(false);

        return await WithStoreAsync(share, store =>
        {
            var status = store.CreateFile(out var handle, out _, path, AccessMask.GENERIC_READ | AccessMask.SYNCHRONIZE, SmbFileAttributes.Directory,
                ShareAccess.Read | ShareAccess.Write, CreateDisposition.FILE_OPEN, CreateOptions.FILE_DIRECTORY_FILE | CreateOptions.FILE_SYNCHRONOUS_IO_NONALERT, null);
            Check(status, "open folder");
            try
            {
                var items = new List<SourceItem>();
                status = store.QueryDirectory(out var entries, handle, "*", FileInformationClass.FileDirectoryInformation);
                if (status != NTStatus.STATUS_NO_MORE_FILES) Check(status, "list folder");
                foreach (var e in entries.OfType<FileDirectoryInformation>())
                {
                    if (e.FileName is "." or ".." || (e.FileAttributes & (SmbFileAttributes.Hidden | SmbFileAttributes.System)) != 0) continue;
                    var childPath = path.Length == 0 ? e.FileName : path + "\\" + e.FileName;
                    var childUri = UriFor(share, childPath);
                    var modified = new DateTimeOffset(DateTime.SpecifyKind(e.LastWriteTime, DateTimeKind.Utc));
                    if ((e.FileAttributes & SmbFileAttributes.Directory) != 0) items.Add(FolderItem(childUri, e.FileName, modified));
                    else items.Add(FileItem(childUri, e.FileName, e.EndOfFile, modified));
                }
                return Sort(items);
            }
            finally { store.CloseFile(handle); }
        }, ct).ConfigureAwait(false);
    }

    public override Task<IReadOnlyList<SourceItem>> SearchAsync(string query, CancellationToken ct = default)
    {
        if (DirectMode || Share is null) throw new NotSupportedException("Search requires a share in system mode.");
        return SearchDirectoryAsync(new[] { PathOf(RootUri) }, query, ct);
    }

    public override async Task<MediaLocation> ResolveAsync(string uri, CancellationToken ct = default)
    {
        if (!DirectMode) return await base.ResolveAsync(uri, ct).ConfigureAwait(false);
        var (_, share, path) = Split(uri);
        var length = await WithStoreAsync(share, store =>
        {
            var h = OpenFile(store, path, AccessMask.GENERIC_READ);
            try { return SizeOf(store, h); }
            finally { store.CloseFile(h); }
        }, ct).ConfigureAwait(false);
        var name = System.IO.Path.GetFileName(path);
        return MediaLocation.ForStream((offset, token) => Task.FromResult<Stream>(new SmbReadStream(this, share, path, offset, length)), length, name);
    }

    public override async Task<Track?> GetTrackAsync(string uri, CancellationToken ct = default)
    {
        if (!DirectMode) return await base.GetTrackAsync(uri, ct).ConfigureAwait(false);
        var loc = await ResolveAsync(uri, ct).ConfigureAwait(false);
        var t = CreateFileTrack(uri, loc.FileName, loc.Length, null);
        return t;
    }

    public override async Task<string> CreateFolderAsync(string parentUri, string name, CancellationToken ct = default)
    {
        if (!DirectMode) return await base.CreateFolderAsync(parentUri, name, ct).ConfigureAwait(false);
        var (_, share, path) = Split(parentUri);
        var newPath = Combine(path, SanitizeName(name));
        await WithStoreAsync(share, store =>
        {
            Check(store.CreateFile(out var h, out _, newPath, AccessMask.GENERIC_READ | AccessMask.GENERIC_WRITE, SmbFileAttributes.Directory,
                ShareAccess.Read | ShareAccess.Write, CreateDisposition.FILE_CREATE, CreateOptions.FILE_DIRECTORY_FILE, null), "create folder");
            store.CloseFile(h);
            return 0;
        }, ct).ConfigureAwait(false);
        return UriFor(share, newPath);
    }

    public override async Task<string> RenameAsync(string uri, string newName, CancellationToken ct = default)
    {
        if (!DirectMode) return await base.RenameAsync(uri, newName, ct).ConfigureAwait(false);
        var (_, share, path) = Split(uri);
        var parent = path.Contains('\\') ? path[..path.LastIndexOf('\\')] : "";
        var target = Combine(parent, SanitizeName(newName));
        await WithStoreAsync(share, store =>
        {
            Check(store.CreateFile(out var h, out _, path, AccessMask.DELETE | AccessMask.SYNCHRONIZE, 0, ShareAccess.Read | ShareAccess.Write | ShareAccess.Delete,
                CreateDisposition.FILE_OPEN, CreateOptions.FILE_SYNCHRONOUS_IO_NONALERT, null), "open for rename");
            try { Check(store.SetFileInformation(h, new FileRenameInformationType2 { FileName = target, ReplaceIfExists = false }), "rename"); }
            finally { store.CloseFile(h); }
            return 0;
        }, ct).ConfigureAwait(false);
        return UriFor(share, target);
    }

    public override async Task DeleteAsync(string uri, CancellationToken ct = default)
    {
        if (!DirectMode) { await base.DeleteAsync(uri, ct).ConfigureAwait(false); return; }
        var (_, share, path) = Split(uri);
        await WithStoreAsync(share, store => { DeleteRecursive(store, path); return 0; }, ct).ConfigureAwait(false);
    }

    private void DeleteRecursive(ISMBFileStore store, string path)
    {
        Check(store.CreateFile(out var h, out _, path, AccessMask.GENERIC_READ | AccessMask.DELETE | AccessMask.SYNCHRONIZE, 0,
            ShareAccess.Read | ShareAccess.Write | ShareAccess.Delete, CreateDisposition.FILE_OPEN, CreateOptions.FILE_SYNCHRONOUS_IO_NONALERT, null), "open for delete");
        try
        {
            if (store.GetFileInformation(out var info, h, FileInformationClass.FileStandardInformation) == NTStatus.STATUS_SUCCESS &&
                info is FileStandardInformation { Directory: true })
            {
                if (store.QueryDirectory(out var entries, h, "*", FileInformationClass.FileDirectoryInformation) == NTStatus.STATUS_SUCCESS)
                    foreach (var e in entries.OfType<FileDirectoryInformation>().Where(e => e.FileName is not "." and not ".."))
                        DeleteRecursive(store, Combine(path, e.FileName));
            }
            Check(store.SetFileInformation(h, new FileDispositionInformation { DeletePending = true }), "delete");
        }
        finally { store.CloseFile(h); }
    }

    public override async Task<string> UploadAsync(string folderUri, string fileName, Stream content, long length, IProgress<long>? progress = null, CancellationToken ct = default)
    {
        if (!DirectMode) return await base.UploadAsync(folderUri, fileName, content, length, progress, ct).ConfigureAwait(false);
        var (_, share, path) = Split(folderUri);
        var target = Combine(path, SanitizeName(fileName));
        object handle = await WithStoreAsync(share, store =>
        {
            Check(store.CreateFile(out var h, out _, target, AccessMask.GENERIC_WRITE | AccessMask.SYNCHRONIZE, SmbFileAttributes.Normal, ShareAccess.None,
                CreateDisposition.FILE_OVERWRITE_IF, CreateOptions.FILE_NON_DIRECTORY_FILE | CreateOptions.FILE_SYNCHRONOUS_IO_ALERT, null), "create file");
            return h;
        }, ct).ConfigureAwait(false);
        try
        {
            var chunk = (int)Math.Min(_client?.MaxWriteSize ?? 65536, 1 << 20);
            var buf = new byte[chunk];
            long offset = 0;
            int n;
            while ((n = await content.ReadAsync(buf, ct).ConfigureAwait(false)) > 0)
            {
                var data = n == buf.Length ? buf : buf[..n];
                var at = offset;
                await WithStoreAsync(share, store =>
                {
                    Check(store.WriteFile(out var written, handle, at, data), "write");
                    return written;
                }, ct).ConfigureAwait(false);
                offset += n;
                progress?.Report(offset);
            }
        }
        finally
        {
            await WithStoreAsync(share, store => store.CloseFile(handle), CancellationToken.None).ConfigureAwait(false);
        }
        return UriFor(share, target);
    }

    private static string Combine(string a, string b) => a.Length == 0 ? b : a + "\\" + b;

    private static object OpenFile(ISMBFileStore store, string path, AccessMask access)
    {
        Check(store.CreateFile(out var h, out _, path, access | AccessMask.SYNCHRONIZE, SmbFileAttributes.Normal, ShareAccess.Read | ShareAccess.Write,
            CreateDisposition.FILE_OPEN, CreateOptions.FILE_NON_DIRECTORY_FILE | CreateOptions.FILE_SYNCHRONOUS_IO_ALERT, null), "open file");
        return h;
    }

    private static long SizeOf(ISMBFileStore store, object handle)
    {
        Check(store.GetFileInformation(out var info, handle, FileInformationClass.FileStandardInformation), "query size");
        return ((FileStandardInformation)info).EndOfFile;
    }

    private static void Check(NTStatus status, string op)
    {
        if (status == NTStatus.STATUS_SUCCESS) return;
        if (status is NTStatus.STATUS_ACCESS_DENIED or NTStatus.STATUS_LOGON_FAILURE)
            throw new SourceAuthenticationException($"SMB {op} failed: {status}");
        throw new SourceException($"SMB {op} failed: {status}");
    }

    private async Task<List<string>> ListSharesDirectAsync(CancellationToken ct)
    {
        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            var client = await EnsureClientAsync(ct).ConfigureAwait(false);
            var shares = client.ListShares(out var status);
            Check(status, "list shares");
            return shares.Where(s => !s.EndsWith('$')).ToList();
        }
        finally { _lock.Release(); }
    }

    internal async Task<T> WithStoreAsync<T>(string share, Func<ISMBFileStore, T> action, CancellationToken ct)
    {
        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            for (var attempt = 0; ; attempt++)
            {
                try
                {
                    await EnsureClientAsync(ct).ConfigureAwait(false);
                    if (!_stores.TryGetValue(share, out var store))
                    {
                        store = _client!.TreeConnect(share, out var status);
                        Check(status, $"connect to share '{share}'");
                        _stores[share] = store;
                    }
                    return action(store);
                }
                catch (Exception ex) when (attempt == 0 && ex is InvalidOperationException or IOException or System.Net.Sockets.SocketException or ObjectDisposedException)
                {
                    _log.LogInformation(ex, "SMB connection lost, reconnecting");
                    ResetClient();
                }
            }
        }
        finally { _lock.Release(); }
    }

    private async Task<SMB2Client> EnsureClientAsync(CancellationToken ct)
    {
        if (_client is { IsConnected: true }) return _client;
        ResetClient();
        var password = await _ctx.SecretAsync(Config, SourceKeys.SecretPassword, ct).ConfigureAwait(false) ?? "";
        var client = new SMB2Client();
        var connected = IPAddress.TryParse(Host, out var ip)
            ? client.Connect(ip, SMBTransportType.DirectTCPTransport)
            : client.Connect(Host, SMBTransportType.DirectTCPTransport);
        if (!connected) throw new SourceException($"Cannot connect to SMB server {Host}.");
        var status = client.Login(Config.Get(SourceKeys.Domain) ?? "", Config.Get(SourceKeys.Username) ?? "", password);
        if (status != NTStatus.STATUS_SUCCESS)
        {
            client.Disconnect();
            throw new SourceAuthenticationException($"SMB login to {Host} failed: {status}");
        }
        _client = client;
        return client;
    }

    private void ResetClient()
    {
        foreach (var s in _stores.Values) { try { s.Disconnect(); } catch (Exception) { } }
        _stores.Clear();
        if (_client is not null)
        {
            try { _client.Logoff(); _client.Disconnect(); } catch (Exception) { }
            _client = null;
        }
    }

    public override async ValueTask DisposeAsync()
    {
        await _lock.WaitAsync().ConfigureAwait(false);
        try { ResetClient(); } finally { _lock.Release(); }
        await base.DisposeAsync().ConfigureAwait(false);
    }

    /// <summary>Sequential/seekable stream over an SMBLibrary file handle.</summary>
    private sealed class SmbReadStream : Stream
    {
        private readonly SmbSource _owner;
        private readonly string _share;
        private readonly string _path;
        private readonly long _length;
        private object? _handle;
        private long _pos;

        public SmbReadStream(SmbSource owner, string share, string path, long offset, long length)
        {
            _owner = owner;
            _share = share;
            _path = path;
            _pos = offset;
            _length = length;
        }

        public override bool CanRead => true;
        public override bool CanSeek => true;
        public override bool CanWrite => false;
        public override long Length => _length;
        public override long Position { get => _pos; set => _pos = value; }
        public override void Flush() { }

        public override int Read(byte[] buffer, int offset, int count) =>
            ReadAsync(buffer.AsMemory(offset, count), CancellationToken.None).AsTask().GetAwaiter().GetResult();

        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default)
        {
            if (_pos >= _length || buffer.Length == 0) return 0;
            var max = (int)Math.Min(Math.Min(buffer.Length, _owner._client?.MaxReadSize ?? 65536), _length - _pos);
            var data = await _owner.WithStoreAsync(_share, store =>
            {
                _handle ??= OpenFile(store, _path, AccessMask.GENERIC_READ);
                var status = store.ReadFile(out var bytes, _handle, _pos, max);
                if (status == NTStatus.STATUS_END_OF_FILE) return Array.Empty<byte>();
                Check(status, "read");
                return bytes;
            }, ct).ConfigureAwait(false);
            data.CopyTo(buffer);
            _pos += data.Length;
            return data.Length;
        }

        public override long Seek(long offset, SeekOrigin origin)
        {
            _pos = origin switch { SeekOrigin.Begin => offset, SeekOrigin.Current => _pos + offset, _ => _length + offset };
            return _pos;
        }

        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();

        protected override void Dispose(bool disposing)
        {
            if (_handle is { } h)
            {
                _handle = null;
                try { _owner.WithStoreAsync(_share, store => store.CloseFile(h), CancellationToken.None).GetAwaiter().GetResult(); }
                catch (Exception) { }
            }
            base.Dispose(disposing);
        }
    }
}

/// <summary>Enumerates disk shares of a server through the Windows NetShareEnum API (uses the current logon).</summary>
internal static class NetShares
{
    [DllImport("netapi32.dll", CharSet = CharSet.Unicode)]
    private static extern int NetShareEnum(string serverName, int level, out IntPtr bufPtr, int prefMaxLen, out int entriesRead, out int totalEntries, ref int resumeHandle);

    [DllImport("netapi32.dll")]
    private static extern int NetApiBufferFree(IntPtr buffer);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ShareInfo1
    {
        public string Name;
        public uint Type;
        public string Remark;
    }

    public static List<string> Enumerate(string server)
    {
        var resume = 0;
        var rc = NetShareEnum(server, 1, out var buf, -1, out var read, out _, ref resume);
        if (rc != 0) throw new SourceException($"Cannot list shares on {server} (error {rc}).");
        try
        {
            var list = new List<string>();
            var size = Marshal.SizeOf<ShareInfo1>();
            for (var i = 0; i < read; i++)
            {
                var info = Marshal.PtrToStructure<ShareInfo1>(buf + i * size);
                if ((info.Type & 0xFF) == 0 && !info.Name.EndsWith('$')) list.Add(info.Name);
            }
            return list;
        }
        finally { NetApiBufferFree(buf); }
    }
}
