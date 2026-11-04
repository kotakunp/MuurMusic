using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Text;
using Microsoft.Extensions.Logging;

namespace MuurMusic.Audio.Casting;

/// <summary>
/// Minimal HTTP/1.1 server that hands track bytes (any <see cref="Core.Sources.MediaLocation"/>, re-resolved per request so
/// expiring URLs stay fresh) and cached artwork files to Chromecast and DLNA renderers on the LAN. Supports Range requests,
/// HEAD and one request per connection. Routes are registered with string keys; at most 64 entries are kept (oldest evicted).
/// </summary>
public sealed class LocalHttpServer : IDisposable
{
    private sealed class Entry
    {
        public required string Mime { get; init; }
        public required Func<long, CancellationToken, Task<Stream>> Open { get; init; }
        public Func<long>? Length { get; init; }
        public long LastUsedTick = Environment.TickCount64;
    }

    private readonly ILogger<LocalHttpServer>? _log;
    private readonly ConcurrentDictionary<string, Entry> _entries = new(StringComparer.Ordinal);
    private readonly object _gate = new();
    private TcpListener? _listener;
    private CancellationTokenSource? _cts;
    private bool _disposed;

    public LocalHttpServer(ILogger<LocalHttpServer>? log = null) => _log = log;

    public bool IsRunning => _listener is not null;
    public int Port { get; private set; }

    public void EnsureStarted()
    {
        lock (_gate)
        {
            if (_listener is not null) return;
            ObjectDisposedException.ThrowIf(_disposed, this);
            _cts = new CancellationTokenSource();
            _listener = new TcpListener(IPAddress.IPv6Any, 0) { Server = { DualMode = true } };
            _listener.Start();
            Port = ((IPEndPoint)_listener.LocalEndpoint).Port;
            _ = Task.Run(() => AcceptLoopAsync(_listener, _cts.Token));
            _log?.LogInformation("Cast HTTP server listening on port {Port}", Port);
        }
    }

    /// <summary>Registers a byte source. <paramref name="open"/> returns a stream positioned at the given byte offset.</summary>
    public void Register(string key, string mime, Func<long, CancellationToken, Task<Stream>> open, Func<long>? length = null)
    {
        EnsureStarted();
        _entries[key] = new Entry { Mime = mime, Open = open, Length = length, LastUsedTick = Environment.TickCount64 };
        if (_entries.Count > 64)
            foreach (var old in _entries.OrderBy(e => e.Value.LastUsedTick).Take(_entries.Count - 64).ToList())
                _entries.TryRemove(old.Key, out _);
    }

    public void RegisterFile(string key, string path, string mime) =>
        Register(key, mime,
            (offset, _) =>
            {
                var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16, FileOptions.Asynchronous | FileOptions.SequentialScan);
                if (offset > 0) fs.Seek(offset, SeekOrigin.Begin);
                return Task.FromResult<Stream>(fs);
            },
            () => new FileInfo(path).Length);

    public void Unregister(string key) => _entries.TryRemove(key, out _);

    /// <summary>Builds the URL for a registered entry as reachable from <paramref name="remoteAddress"/> (picks the right local interface).</summary>
    public Uri UrlFor(string key, string? fileName, IPAddress? remoteAddress)
    {
        EnsureStarted();
        var local = LocalAddressFor(remoteAddress);
        var name = string.IsNullOrEmpty(fileName) ? "" : "/" + Uri.EscapeDataString(fileName);
        return new Uri($"http://{local}:{Port}/m/{Uri.EscapeDataString(key)}{name}");
    }

    /// <summary>The local IPv4 address used to reach <paramref name="remote"/> (or the first LAN address when null).</summary>
    public static IPAddress LocalAddressFor(IPAddress? remote)
    {
        if (remote is not null)
        {
            try
            {
                using var udp = new UdpClient();
                udp.Connect(remote, 80);
                return ((IPEndPoint)udp.Client.LocalEndPoint!).Address;
            }
            catch (SocketException) { }
        }
        return Core.Discovery.Ssdp.LocalIPv4Addresses().FirstOrDefault() ?? IPAddress.Loopback;
    }

    private async Task AcceptLoopAsync(TcpListener listener, CancellationToken ct)
    {
        try
        {
            while (!ct.IsCancellationRequested)
            {
                var client = await listener.AcceptTcpClientAsync(ct).ConfigureAwait(false);
                _ = Task.Run(() => HandleAsync(client, ct), ct);
            }
        }
        catch (OperationCanceledException) { }
        catch (SocketException) when (ct.IsCancellationRequested) { }
        catch (ObjectDisposedException) { }
        catch (Exception ex) { _log?.LogWarning(ex, "Cast HTTP server accept loop failed"); }
    }

    private async Task HandleAsync(TcpClient client, CancellationToken ct)
    {
        try
        {
            client.NoDelay = true;
            client.ReceiveTimeout = 15000;
            client.SendTimeout = 60000;
            using (client)
            {
                var stream = client.GetStream();
                var (method, path, range) = await ReadRequestAsync(stream, ct).ConfigureAwait(false);
                if (method is null) return;
                var key = Uri.UnescapeDataString(path.Split('/').Skip(2).FirstOrDefault() ?? "");
                if (!_entries.TryGetValue(key, out var entry) || method is not ("GET" or "HEAD"))
                {
                    await WriteResponseHeadAsync(stream, "404 Not Found", null, 0, null, ct).ConfigureAwait(false);
                    return;
                }
                entry.LastUsedTick = Environment.TickCount64;
                long total = -1;
                try { total = entry.Length?.Invoke() ?? -1; } catch (Exception ex) { _log?.LogDebug(ex, "Length probe failed for {Key}", key); }
                long offset = 0, count = total;
                var partial = false;
                if (range is { } r)
                {
                    if (total > 0)
                    {
                        offset = r.Start < 0 ? Math.Max(0, total + r.Start) : Math.Min(r.Start, total - 1);
                        var end = r.End < 0 ? total - 1 : Math.Min(r.End, total - 1);
                        count = Math.Max(0, end - offset + 1);
                        partial = offset > 0 || count < total;
                    }
                    else if (r.Start >= 0)
                    {
                        offset = r.Start;
                        count = -1;
                        partial = true;
                    }
                }
                Stream body;
                try { body = await entry.Open(offset, ct).ConfigureAwait(false); }
                catch (Exception ex)
                {
                    _log?.LogDebug(ex, "Opening cast source {Key} failed", key);
                    await WriteResponseHeadAsync(stream, "502 Bad Gateway", null, 0, null, ct).ConfigureAwait(false);
                    return;
                }
                await using (body.ConfigureAwait(false))
                {
                    var sendLength = count >= 0 ? count : total > 0 ? total - offset : -1;
                    string? contentRange = null;
                    if (partial && total > 0)
                        contentRange = $"bytes {offset}-{offset + Math.Max(0, sendLength) - 1}/{total}";
                    await WriteResponseHeadAsync(stream, partial ? "206 Partial Content" : "200 OK", entry.Mime, sendLength, contentRange, ct).ConfigureAwait(false);
                    if (method == "GET")
                    {
                        var buffer = new byte[1 << 16];
                        var remaining = sendLength;
                        while (remaining != 0 && !ct.IsCancellationRequested)
                        {
                            var want = remaining > 0 ? (int)Math.Min(buffer.Length, remaining) : buffer.Length;
                            var n = await body.ReadAsync(buffer.AsMemory(0, want), ct).ConfigureAwait(false);
                            if (n <= 0) break;
                            await stream.WriteAsync(buffer.AsMemory(0, n), ct).ConfigureAwait(false);
                            if (remaining > 0) remaining -= n;
                        }
                    }
                }
            }
        }
        catch (OperationCanceledException) { }
        catch (IOException) { }
        catch (SocketException) { }
        catch (Exception ex) { _log?.LogDebug(ex, "Cast HTTP request failed"); }
    }

    private static async Task<(string? Method, string Path, (long Start, long End)? Range)> ReadRequestAsync(NetworkStream stream, CancellationToken ct)
    {
        var sb = new StringBuilder(1024);
        var buf = new byte[1];
        var last4 = 0;
        while (sb.Length < 65536)
        {
            var n = await stream.ReadAsync(buf, ct).ConfigureAwait(false);
            if (n == 0) break;
            var b = buf[0];
            sb.Append((char)b);
            last4 = ((last4 << 8) | b) & -1;
            if (last4 == 0x0D0A0D0A) break;
        }
        var lines = sb.ToString().Split("\r\n", StringSplitOptions.RemoveEmptyEntries);
        if (lines.Length == 0) return (null, "", null);
        var parts = lines[0].Split(' ');
        if (parts.Length < 2) return (null, "", null);
        (long Start, long End)? range = null;
        foreach (var line in lines.Skip(1))
        {
            if (!line.StartsWith("Range:", StringComparison.OrdinalIgnoreCase)) continue;
            var v = line[6..].Trim();
            if (!v.StartsWith("bytes=", StringComparison.OrdinalIgnoreCase)) continue;
            var span = v[6..].Split(',')[0].Trim().Split('-');
            if (span.Length != 2) continue;
            if (span[0].Length == 0 && long.TryParse(span[1], out var suffix)) range = (-suffix, -1);
            else if (long.TryParse(span[0], out var start)) range = (start, long.TryParse(span[1], out var end) ? end : -1);
        }
        return (parts[0].ToUpperInvariant(), parts[1], range);
    }

    private static async Task WriteResponseHeadAsync(NetworkStream stream, string status, string? mime, long length, string? contentRange, CancellationToken ct)
    {
        var sb = new StringBuilder(256);
        sb.Append("HTTP/1.1 ").Append(status).Append("\r\n");
        if (mime is not null) sb.Append("Content-Type: ").Append(mime).Append("\r\n");
        sb.Append("Accept-Ranges: bytes\r\n");
        if (length >= 0) sb.Append("Content-Length: ").Append(length).Append("\r\n");
        if (contentRange is not null) sb.Append("Content-Range: ").Append(contentRange).Append("\r\n");
        if (mime is not null) sb.Append("contentFeatures.dlna.org: DLNA.ORG_OP=01;DLNA.ORG_FLAGS=01700000000000000000000000000000\r\n");
        sb.Append("Connection: close\r\n\r\n");
        var bytes = Encoding.ASCII.GetBytes(sb.ToString());
        await stream.WriteAsync(bytes, ct).ConfigureAwait(false);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        lock (_gate)
        {
            _cts?.Cancel();
            _listener?.Stop();
            _listener = null;
            _cts?.Dispose();
            _cts = null;
        }
    }
}
