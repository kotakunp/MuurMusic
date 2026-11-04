using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Xml.Linq;

namespace MuurMusic.Core.Discovery;

/// <summary>One SSDP search response / advertisement.</summary>
public sealed record SsdpResponse(string Location, string SearchTarget, string Usn, string? Server, IPAddress From);

/// <summary>Parsed UPnP device description.</summary>
public sealed record UpnpDevice(string Location, string FriendlyName, string DeviceType, string Udn, string? Manufacturer, string? ModelName, string? IconUrl, IReadOnlyList<UpnpService> Services)
{
    public UpnpService? FindService(string typeFragment) => Services.FirstOrDefault(s => s.ServiceType.Contains(typeFragment, StringComparison.OrdinalIgnoreCase));
}

public sealed record UpnpService(string ServiceType, string ServiceId, string ControlUrl, string EventSubUrl, string ScpdUrl);

/// <summary>SSDP M-SEARCH client (UDP multicast 239.255.255.250:1900) on every active IPv4 interface.</summary>
public static class Ssdp
{
    public const string MediaServer = "urn:schemas-upnp-org:device:MediaServer:1";
    public const string MediaRenderer = "urn:schemas-upnp-org:device:MediaRenderer:1";
    private static readonly IPEndPoint Multicast = new(IPAddress.Parse("239.255.255.250"), 1900);

    public static async Task<IReadOnlyList<SsdpResponse>> SearchAsync(string searchTarget, TimeSpan duration, CancellationToken ct = default, Action<SsdpResponse>? onFound = null)
    {
        var results = new Dictionary<string, SsdpResponse>(StringComparer.OrdinalIgnoreCase);
        var request = Encoding.ASCII.GetBytes(
            "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\n" +
            $"ST: {searchTarget}\r\nUSER-AGENT: Windows/10 UPnP/1.1 MuurMusic/1.0\r\n\r\n");
        var sockets = new List<UdpClient>();
        foreach (var addr in LocalIPv4Addresses())
        {
            try
            {
                var udp = new UdpClient(new IPEndPoint(addr, 0));
                udp.Client.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastTimeToLive, 4);
                sockets.Add(udp);
            }
            catch (SocketException) { }
        }
        if (sockets.Count == 0)
        {
            var udp = new UdpClient(0);
            sockets.Add(udp);
        }
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(duration);
        try
        {
            foreach (var s in sockets)
            {
                for (var i = 0; i < 2; i++)
                    try { await s.SendAsync(request, request.Length, Multicast).ConfigureAwait(false); } catch (SocketException) { }
            }
            await Task.WhenAll(sockets.Select(s => ReceiveLoopAsync(s, results, searchTarget, onFound, cts.Token))).ConfigureAwait(false);
        }
        finally
        {
            foreach (var s in sockets) s.Dispose();
        }
        ct.ThrowIfCancellationRequested();
        lock (results) return results.Values.ToList();
    }

    private static async Task ReceiveLoopAsync(UdpClient udp, Dictionary<string, SsdpResponse> results, string st, Action<SsdpResponse>? onFound, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            UdpReceiveResult r;
            try { r = await udp.ReceiveAsync(ct).ConfigureAwait(false); }
            catch (OperationCanceledException) { return; }
            catch (SocketException) { return; }
            catch (ObjectDisposedException) { return; }
            var resp = Parse(Encoding.UTF8.GetString(r.Buffer), r.RemoteEndPoint.Address);
            if (resp is null) continue;
            if (st != "ssdp:all" && !resp.SearchTarget.Equals(st, StringComparison.OrdinalIgnoreCase) && !resp.Usn.Contains(st, StringComparison.OrdinalIgnoreCase)) continue;
            bool added;
            lock (results) added = results.TryAdd(resp.Location, resp);
            if (added) onFound?.Invoke(resp);
        }
    }

    internal static SsdpResponse? Parse(string text, IPAddress from)
    {
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in text.Split("\r\n").Skip(1))
        {
            var colon = line.IndexOf(':');
            if (colon > 0) headers[line[..colon].Trim()] = line[(colon + 1)..].Trim();
        }
        if (!headers.TryGetValue("LOCATION", out var loc)) return null;
        return new SsdpResponse(loc, headers.GetValueOrDefault("ST") ?? headers.GetValueOrDefault("NT") ?? "", headers.GetValueOrDefault("USN") ?? loc, headers.GetValueOrDefault("SERVER"), from);
    }

    public static IEnumerable<IPAddress> LocalIPv4Addresses() =>
        NetworkInterface.GetAllNetworkInterfaces()
            .Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType != NetworkInterfaceType.Loopback && n.SupportsMulticast)
            .SelectMany(n => n.GetIPProperties().UnicastAddresses)
            .Where(a => a.Address.AddressFamily == AddressFamily.InterNetwork)
            .Select(a => a.Address);

    /// <summary>Downloads and parses a device description XML.</summary>
    public static async Task<UpnpDevice> GetDeviceAsync(HttpClient http, string location, CancellationToken ct = default)
    {
        var xml = await http.GetStringAsync(location, ct).ConfigureAwait(false);
        return ParseDevice(xml, location);
    }

    public static UpnpDevice ParseDevice(string xml, string location)
    {
        var doc = XDocument.Parse(xml);
        XNamespace ns = doc.Root!.Name.Namespace;
        var baseUrl = doc.Root.Element(ns + "URLBase")?.Value is { Length: > 0 } ub ? ub : location;
        var device = doc.Root.Element(ns + "device") ?? throw new FormatException("No device element.");
        var services = device.DescendantsAndSelf(ns + "device").SelectMany(d => d.Element(ns + "serviceList")?.Elements(ns + "service") ?? Enumerable.Empty<XElement>())
            .Select(s => new UpnpService(
                s.Element(ns + "serviceType")?.Value ?? "",
                s.Element(ns + "serviceId")?.Value ?? "",
                Absolute(baseUrl, s.Element(ns + "controlURL")?.Value),
                Absolute(baseUrl, s.Element(ns + "eventSubURL")?.Value),
                Absolute(baseUrl, s.Element(ns + "SCPDURL")?.Value))).ToList();
        var icon = device.Element(ns + "iconList")?.Elements(ns + "icon")
            .OrderByDescending(i => int.TryParse(i.Element(ns + "width")?.Value, out var w) ? w : 0)
            .Select(i => i.Element(ns + "url")?.Value).FirstOrDefault(u => u is not null);
        return new UpnpDevice(location,
            device.Element(ns + "friendlyName")?.Value ?? "UPnP device",
            device.Element(ns + "deviceType")?.Value ?? "",
            device.Element(ns + "UDN")?.Value ?? location,
            device.Element(ns + "manufacturer")?.Value,
            device.Element(ns + "modelName")?.Value,
            icon is null ? null : Absolute(baseUrl, icon),
            services);
    }

    internal static string Absolute(string baseUrl, string? relative)
    {
        if (string.IsNullOrEmpty(relative)) return "";
        return Uri.TryCreate(new Uri(baseUrl), relative, out var u) ? u.AbsoluteUri : relative;
    }

    /// <summary>Invokes a UPnP SOAP action and returns the response body element.</summary>
    public static async Task<XElement> SoapAsync(HttpClient http, string controlUrl, string serviceType, string action, IEnumerable<(string Name, string Value)> args, CancellationToken ct = default)
    {
        var argXml = string.Concat(args.Select(a => $"<{a.Name}>{System.Security.SecurityElement.Escape(a.Value)}</{a.Name}>"));
        var body = "<?xml version=\"1.0\" encoding=\"utf-8\"?>" +
                   "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">" +
                   $"<s:Body><u:{action} xmlns:u=\"{serviceType}\">{argXml}</u:{action}></s:Body></s:Envelope>";
        using var req = new HttpRequestMessage(HttpMethod.Post, controlUrl) { Content = new StringContent(body, Encoding.UTF8, "text/xml") };
        req.Content.Headers.ContentType!.CharSet = "utf-8";
        req.Headers.TryAddWithoutValidation("SOAPAction", $"\"{serviceType}#{action}\"");
        using var resp = await http.SendAsync(req, ct).ConfigureAwait(false);
        var text = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        XDocument doc;
        try { doc = XDocument.Parse(text); }
        catch (System.Xml.XmlException) { throw new Sources.SourceException($"UPnP {action} failed: HTTP {(int)resp.StatusCode}"); }
        var fault = doc.Descendants().FirstOrDefault(e => e.Name.LocalName == "Fault");
        if (fault is not null || !resp.IsSuccessStatusCode)
        {
            var desc = doc.Descendants().FirstOrDefault(e => e.Name.LocalName == "errorDescription")?.Value
                ?? doc.Descendants().FirstOrDefault(e => e.Name.LocalName == "faultstring")?.Value ?? $"HTTP {(int)resp.StatusCode}";
            throw new Sources.SourceException($"UPnP {action} failed: {desc}");
        }
        return doc.Descendants().First(e => e.Name.LocalName == action + "Response");
    }
}
