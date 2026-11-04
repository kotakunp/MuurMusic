using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Logging;
using MuurMusic.Core.Models;
using MuurMusic.Core.Sources;
using Zeroconf;

namespace MuurMusic.Core.Discovery;

public enum DiscoveredServerKind { Smb, WebDav, Sftp, Ftp, Upnp, Jellyfin, Emby, Plex }

/// <summary>A server found on the local network.</summary>
public sealed record DiscoveredServer(DiscoveredServerKind Kind, string Name, string Host, int Port, string? Url, string Id, IReadOnlyDictionary<string, string> Properties)
{
    /// <summary>Pre-filled (unsaved) source configuration for this server. Credentials still need to be supplied.</summary>
    public SourceConfig ToSourceConfig()
    {
        var c = new SourceConfig { Name = Name };
        switch (Kind)
        {
            case DiscoveredServerKind.Smb: c.Kind = SourceKind.Smb; c.Set(SourceKeys.Host, Host); break;
            case DiscoveredServerKind.WebDav:
                c.Kind = SourceKind.WebDav;
                c.Set(SourceKeys.BaseUrl, Url ?? $"http://{Host}:{Port}/");
                break;
            case DiscoveredServerKind.Sftp: c.Kind = SourceKind.Sftp; c.Set(SourceKeys.Host, Host).Set(SourceKeys.Port, Port.ToString()); break;
            case DiscoveredServerKind.Ftp: c.Kind = SourceKind.Ftp; c.Set(SourceKeys.Host, Host).Set(SourceKeys.Port, Port.ToString()); break;
            case DiscoveredServerKind.Upnp: c.Kind = SourceKind.Upnp; c.Set(SourceKeys.DeviceLocation, Url).Set(SourceKeys.ServerId, Id); break;
            case DiscoveredServerKind.Jellyfin: c.Kind = SourceKind.Jellyfin; c.Set(SourceKeys.ServerUrl, Url).Set(SourceKeys.ServerId, Id); break;
            case DiscoveredServerKind.Emby: c.Kind = SourceKind.Emby; c.Set(SourceKeys.ServerUrl, Url).Set(SourceKeys.ServerId, Id); break;
            case DiscoveredServerKind.Plex: c.Kind = SourceKind.Plex; c.Set(SourceKeys.ServerUrl, Url).Set(SourceKeys.ServerId, Id); break;
        }
        return c;
    }
}

/// <summary>Finds music servers on the LAN via mDNS/DNS-SD (Zeroconf), SSDP, Jellyfin/Emby UDP discovery and Plex GDM.</summary>
public interface INetworkDiscovery
{
    /// <summary>Scans for <paramref name="duration"/>; <paramref name="found"/> is invoked (on a background thread) for each new server.</summary>
    Task<IReadOnlyList<DiscoveredServer>> ScanAsync(TimeSpan duration, Action<DiscoveredServer>? found = null, CancellationToken ct = default);
}

public sealed class NetworkDiscovery(IHttpClientFactory httpFactory, ILogger<NetworkDiscovery> logger) : INetworkDiscovery
{
    private static readonly (string Service, DiscoveredServerKind Kind)[] MdnsServices =
    {
        ("_smb._tcp.local.", DiscoveredServerKind.Smb),
        ("_webdav._tcp.local.", DiscoveredServerKind.WebDav),
        ("_webdavs._tcp.local.", DiscoveredServerKind.WebDav),
        ("_sftp-ssh._tcp.local.", DiscoveredServerKind.Sftp),
        ("_ftp._tcp.local.", DiscoveredServerKind.Ftp),
        ("_plexmediasvr._tcp.local.", DiscoveredServerKind.Plex),
    };

    public async Task<IReadOnlyList<DiscoveredServer>> ScanAsync(TimeSpan duration, Action<DiscoveredServer>? found = null, CancellationToken ct = default)
    {
        var results = new Dictionary<string, DiscoveredServer>(StringComparer.OrdinalIgnoreCase);
        void Add(DiscoveredServer s)
        {
            bool added;
            lock (results) added = results.TryAdd($"{s.Kind}|{s.Id}|{s.Host}:{s.Port}", s);
            if (added) found?.Invoke(s);
        }

        var tasks = new[]
        {
            Safe(() => MdnsAsync(duration, Add, ct), "mDNS"),
            Safe(() => SsdpAsync(duration, Add, ct), "SSDP"),
            Safe(() => BroadcastAsync("who is JellyfinServer?", DiscoveredServerKind.Jellyfin, duration, Add, ct), "Jellyfin"),
            Safe(() => BroadcastAsync("who is EmbyServer?", DiscoveredServerKind.Emby, duration, Add, ct), "Emby"),
            Safe(() => PlexGdmAsync(duration, Add, ct), "Plex GDM"),
        };
        await Task.WhenAll(tasks).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        lock (results) return results.Values.OrderBy(r => r.Kind).ThenBy(r => r.Name, StringComparer.CurrentCultureIgnoreCase).ToList();
    }

    private async Task Safe(Func<Task> run, string name)
    {
        try { await run().ConfigureAwait(false); }
        catch (OperationCanceledException) { }
        catch (Exception ex) when (ex is SocketException or HttpRequestException or IOException or InvalidOperationException or FormatException or System.Xml.XmlException or ArgumentException)
        {
            logger.LogDebug(ex, "{Name} discovery failed", name);
        }
    }

    private static async Task MdnsAsync(TimeSpan duration, Action<DiscoveredServer> add, CancellationToken ct)
    {
        var hosts = await ZeroconfResolver.ResolveAsync(MdnsServices.Select(s => s.Service), duration, 2, 1000, null, ct).ConfigureAwait(false);
        foreach (var host in hosts)
        {
            foreach (var (name, svc) in host.Services)
            {
                var match = MdnsServices.FirstOrDefault(m => name.StartsWith(m.Service.TrimEnd('.'), StringComparison.OrdinalIgnoreCase) || name.Contains(m.Service.Replace(".local.", ""), StringComparison.OrdinalIgnoreCase));
                if (match.Service is null) continue;
                var props = svc.Properties.SelectMany(p => p).GroupBy(p => p.Key).ToDictionary(g => g.Key, g => g.First().Value);
                string? url = null;
                if (match.Kind == DiscoveredServerKind.WebDav)
                {
                    var https = name.Contains("webdavs", StringComparison.OrdinalIgnoreCase);
                    var path = props.GetValueOrDefault("path") ?? "/";
                    url = $"{(https ? "https" : "http")}://{host.IPAddress}:{svc.Port}{(path.StartsWith('/') ? path : "/" + path)}";
                }
                else if (match.Kind == DiscoveredServerKind.Plex) url = $"http://{host.IPAddress}:{svc.Port}";
                add(new DiscoveredServer(match.Kind, host.DisplayName, host.IPAddress, svc.Port, url, host.Id ?? host.IPAddress, props));
            }
        }
    }

    private async Task SsdpAsync(TimeSpan duration, Action<DiscoveredServer> add, CancellationToken ct)
    {
        var http = httpFactory.CreateClient(HttpClientNames.Default);
        var pending = new List<Task>();
        await Ssdp.SearchAsync(Ssdp.MediaServer, duration, ct, r =>
        {
            lock (pending)
                pending.Add(Task.Run(async () =>
                {
                    try
                    {
                        var device = await Ssdp.GetDeviceAsync(http, r.Location, ct).ConfigureAwait(false);
                        if (device.FindService("ContentDirectory") is null) return;
                        var uri = new Uri(r.Location);
                        add(new DiscoveredServer(DiscoveredServerKind.Upnp, device.FriendlyName, uri.Host, uri.Port, r.Location, device.Udn,
                            new Dictionary<string, string> { ["manufacturer"] = device.Manufacturer ?? "", ["model"] = device.ModelName ?? "" }));
                    }
                    catch (Exception ex) when (ex is HttpRequestException or System.Xml.XmlException or FormatException or TaskCanceledException) { }
                }, ct));
        }).ConfigureAwait(false);
        Task[] all;
        lock (pending) all = pending.ToArray();
        await Task.WhenAll(all).ConfigureAwait(false);
    }

    private static async Task BroadcastAsync(string message, DiscoveredServerKind kind, TimeSpan duration, Action<DiscoveredServer> add, CancellationToken ct)
    {
        using var udp = new UdpClient(0) { EnableBroadcast = true };
        var bytes = Encoding.ASCII.GetBytes(message);
        await udp.SendAsync(bytes, bytes.Length, new IPEndPoint(IPAddress.Broadcast, 7359)).ConfigureAwait(false);
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(duration);
        while (!cts.IsCancellationRequested)
        {
            UdpReceiveResult r;
            try { r = await udp.ReceiveAsync(cts.Token).ConfigureAwait(false); }
            catch (OperationCanceledException) { break; }
            try
            {
                using var doc = JsonDocument.Parse(r.Buffer);
                var root = doc.RootElement;
                var address = root.TryGetProperty("Address", out var a) ? a.GetString() : null;
                var id = root.TryGetProperty("Id", out var i) ? i.GetString() ?? "" : "";
                var name = root.TryGetProperty("Name", out var n) ? n.GetString() ?? kind.ToString() : kind.ToString();
                if (address is null || !Uri.TryCreate(address, UriKind.Absolute, out var u)) continue;
                add(new DiscoveredServer(kind, name, u.Host, u.Port, address.TrimEnd('/'), id, new Dictionary<string, string>()));
            }
            catch (JsonException) { }
        }
    }

    private static async Task PlexGdmAsync(TimeSpan duration, Action<DiscoveredServer> add, CancellationToken ct)
    {
        using var udp = new UdpClient(0) { EnableBroadcast = true };
        var bytes = Encoding.ASCII.GetBytes("M-SEARCH * HTTP/1.1\r\n\r\n");
        await udp.SendAsync(bytes, bytes.Length, new IPEndPoint(IPAddress.Parse("239.0.0.250"), 32414)).ConfigureAwait(false);
        await udp.SendAsync(bytes, bytes.Length, new IPEndPoint(IPAddress.Broadcast, 32414)).ConfigureAwait(false);
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(duration);
        while (!cts.IsCancellationRequested)
        {
            UdpReceiveResult r;
            try { r = await udp.ReceiveAsync(cts.Token).ConfigureAwait(false); }
            catch (OperationCanceledException) { break; }
            var headers = Encoding.UTF8.GetString(r.Buffer).Split('\n')
                .Select(l => l.Trim()).Where(l => l.Contains(':'))
                .Select(l => (K: l[..l.IndexOf(':')].Trim(), V: l[(l.IndexOf(':') + 1)..].Trim()))
                .GroupBy(h => h.K, StringComparer.OrdinalIgnoreCase).ToDictionary(g => g.Key, g => g.First().V, StringComparer.OrdinalIgnoreCase);
            if (!headers.TryGetValue("Port", out var portText) || !int.TryParse(portText, out var port)) continue;
            var host = r.RemoteEndPoint.Address.ToString();
            add(new DiscoveredServer(DiscoveredServerKind.Plex, headers.GetValueOrDefault("Name") ?? "Plex Media Server", host, port,
                $"http://{host}:{port}", headers.GetValueOrDefault("Resource-Identifier") ?? host, headers));
        }
    }
}
