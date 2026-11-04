using System.Globalization;
using System.Xml.Linq;
using MuurMusic.Core.Discovery;
using MuurMusic.Core.Models;

namespace MuurMusic.Core.Sources;

/// <summary>An object parsed from DIDL-Lite.</summary>
public sealed record DidlObject(string Id, string ParentId, bool IsContainer, string Title, string? Creator, string? Artist, string? Album, string? Genre,
    int? TrackNumber, string? Date, string? AlbumArtUri, int? ChildCount, string? ResourceUrl, string? ProtocolInfo, long Size, long DurationMs,
    int Bitrate, int SampleRate, int BitsPerSample, int Channels, string? UpnpClass);

/// <summary>DIDL-Lite parsing and generation (ContentDirectory results, AVTransport metadata).</summary>
public static class Didl
{
    private static readonly XNamespace DidlNs = "urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/";
    private static readonly XNamespace Dc = "http://purl.org/dc/elements/1.1/";
    private static readonly XNamespace Upnp = "urn:schemas-upnp-org:metadata-1-0/upnp/";

    public static IReadOnlyList<DidlObject> Parse(string didl)
    {
        if (string.IsNullOrWhiteSpace(didl)) return Array.Empty<DidlObject>();
        var doc = XDocument.Parse(didl);
        var list = new List<DidlObject>();
        foreach (var e in doc.Root!.Elements())
        {
            var isContainer = e.Name.LocalName == "container";
            if (!isContainer && e.Name.LocalName != "item") continue;
            var res = e.Elements(DidlNs + "res")
                .OrderByDescending(r => (r.Attribute("protocolInfo")?.Value ?? "").Contains(":audio/", StringComparison.OrdinalIgnoreCase))
                .FirstOrDefault();
            list.Add(new DidlObject(
                e.Attribute("id")?.Value ?? "",
                e.Attribute("parentID")?.Value ?? "",
                isContainer,
                e.Element(Dc + "title")?.Value ?? "",
                e.Element(Dc + "creator")?.Value,
                e.Elements(Upnp + "artist").Select(a => a.Value).FirstOrDefault(),
                e.Element(Upnp + "album")?.Value,
                e.Element(Upnp + "genre")?.Value,
                int.TryParse(e.Element(Upnp + "originalTrackNumber")?.Value, out var tn) ? tn : null,
                e.Element(Dc + "date")?.Value,
                e.Element(Upnp + "albumArtURI")?.Value,
                int.TryParse(e.Attribute("childCount")?.Value, out var cc) ? cc : null,
                res?.Value.Trim(),
                res?.Attribute("protocolInfo")?.Value,
                long.TryParse(res?.Attribute("size")?.Value, out var size) ? size : 0,
                ParseDuration(res?.Attribute("duration")?.Value),
                int.TryParse(res?.Attribute("bitrate")?.Value, out var br) ? br * 8 / 1000 : 0,
                int.TryParse(res?.Attribute("sampleFrequency")?.Value, out var sf) ? sf : 0,
                int.TryParse(res?.Attribute("bitsPerSample")?.Value, out var bps) ? bps : 0,
                int.TryParse(res?.Attribute("nrAudioChannels")?.Value, out var ch) ? ch : 0,
                e.Element(Upnp + "class")?.Value));
        }
        return list;
    }

    /// <summary>Parses H:MM:SS(.fff) durations to milliseconds.</summary>
    public static long ParseDuration(string? s)
    {
        if (string.IsNullOrEmpty(s)) return 0;
        var parts = s.Split(':');
        if (parts.Length != 3) return 0;
        if (!int.TryParse(parts[0], out var h) || !int.TryParse(parts[1], out var m) ||
            !double.TryParse(parts[2], NumberStyles.Float, CultureInfo.InvariantCulture, out var sec)) return 0;
        return (long)((h * 3600 + m * 60 + sec) * 1000);
    }

    public static string FormatDuration(TimeSpan t) => $"{(int)t.TotalHours}:{t.Minutes:00}:{t.Seconds:00}.{t.Milliseconds:000}";

    /// <summary>Builds single-item DIDL-Lite metadata for AVTransport SetAVTransportURI.</summary>
    public static string BuildItem(string url, string mime, string title, string? artist, string? album, string? artUrl, TimeSpan duration, long size = 0)
    {
        var res = new XElement(DidlNs + "res", new XAttribute("protocolInfo", $"http-get:*:{mime}:DLNA.ORG_OP=01;DLNA.ORG_FLAGS=01700000000000000000000000000000"), url);
        if (duration > TimeSpan.Zero) res.Add(new XAttribute("duration", FormatDuration(duration)));
        if (size > 0) res.Add(new XAttribute("size", size));
        var item = new XElement(DidlNs + "item", new XAttribute("id", "0"), new XAttribute("parentID", "-1"), new XAttribute("restricted", "1"),
            new XElement(Dc + "title", title),
            new XElement(Upnp + "class", "object.item.audioItem.musicTrack"));
        if (artist is not null) { item.Add(new XElement(Dc + "creator", artist)); item.Add(new XElement(Upnp + "artist", artist)); }
        if (album is not null) item.Add(new XElement(Upnp + "album", album));
        if (artUrl is not null) item.Add(new XElement(Upnp + "albumArtURI", artUrl));
        item.Add(res);
        var root = new XElement(DidlNs + "DIDL-Lite",
            new XAttribute(XNamespace.Xmlns + "dc", Dc.NamespaceName),
            new XAttribute(XNamespace.Xmlns + "upnp", Upnp.NamespaceName),
            item);
        return root.ToString(SaveOptions.DisableFormatting);
    }
}

/// <summary>DLNA / UPnP AV media server (ContentDirectory). URIs: <c>upnp://&lt;sourceId&gt;/&lt;objectId&gt;</c>.</summary>
public sealed class UpnpSource(SourceConfig config, SourceContext ctx) : MusicSourceBase(config)
{
    private UpnpService? _cds;
    private bool? _canSearch;

    public override SourceCapabilities Capabilities => SourceCapabilities.Browse | (_canSearch == false ? 0 : SourceCapabilities.Search);
    public override string RootUri => SourceUris.ForSourceScoped(SourceUris.Upnp, Config.Id, "0");
    public override bool Owns(string uri) => SourceUris.TryParseSourceScoped(uri, out var s, out var id, out _) && s == SourceUris.Upnp && id == Config.Id;

    private string IdOf(string? uri) => uri is null ? "0" : SourceUris.TryParseSourceScoped(uri, out _, out _, out var item) && item.Length > 0 ? item : "0";
    private string UriOf(string objectId) => SourceUris.ForSourceScoped(SourceUris.Upnp, Config.Id, objectId);

    private async Task<UpnpService> ContentDirectoryAsync(CancellationToken ct)
    {
        if (_cds is not null) return _cds;
        var location = Config.Get(SourceKeys.DeviceLocation) ?? throw new SourceException("Media server location is not set.");
        UpnpDevice device;
        try { device = await Ssdp.GetDeviceAsync(ctx.Http, location, ct).ConfigureAwait(false); }
        catch (HttpRequestException)
        {
            // The server may have moved to another port/IP; rediscover it by UDN.
            var udn = Config.Get(SourceKeys.ServerId);
            var found = udn is null ? null : (await Ssdp.SearchAsync(Ssdp.MediaServer, TimeSpan.FromSeconds(3), ct).ConfigureAwait(false))
                .FirstOrDefault(r => r.Usn.StartsWith(udn, StringComparison.OrdinalIgnoreCase));
            if (found is null) throw new SourceException($"{Config.Name} is not reachable.");
            Config.Set(SourceKeys.DeviceLocation, found.Location);
            device = await Ssdp.GetDeviceAsync(ctx.Http, found.Location, ct).ConfigureAwait(false);
        }
        _cds = device.FindService("ContentDirectory") ?? throw new SourceException("Device has no ContentDirectory service.");
        return _cds;
    }

    private async Task<IReadOnlyList<DidlObject>> BrowseAsync(string objectId, string flag, CancellationToken ct)
    {
        var cds = await ContentDirectoryAsync(ct).ConfigureAwait(false);
        var all = new List<DidlObject>();
        var start = 0;
        while (true)
        {
            var resp = await Ssdp.SoapAsync(ctx.Http, cds.ControlUrl, cds.ServiceType, "Browse", new[]
            {
                ("ObjectID", objectId), ("BrowseFlag", flag), ("Filter", "*"),
                ("StartingIndex", start.ToString(CultureInfo.InvariantCulture)), ("RequestedCount", "500"), ("SortCriteria", "")
            }, ct).ConfigureAwait(false);
            var page = Didl.Parse(resp.Element("Result")?.Value ?? "");
            all.AddRange(page);
            if (flag == "BrowseMetadata") break;
            var returned = int.TryParse(resp.Element("NumberReturned")?.Value, out var nr) ? nr : page.Count;
            var total = int.TryParse(resp.Element("TotalMatches")?.Value, out var tm) ? tm : 0;
            start += returned;
            if (returned == 0 || (total > 0 && start >= total) || (total == 0 && page.Count < 500)) break;
        }
        return all;
    }

    private Track ToTrack(DidlObject o)
    {
        var mime = o.ProtocolInfo?.Split(':').ElementAtOrDefault(2);
        var ext = MimeToExtension(mime) ?? Path.GetExtension(new Uri(o.ResourceUrl ?? "http://x/a", UriKind.Absolute).AbsolutePath).TrimStart('.');
        return new Track
        {
            SourceUri = UriOf(o.Id), SourceId = Config.Id, IsRemote = true,
            FileName = o.Title + (ext.Length > 0 ? "." + ext : ""), Title = o.Title, Artist = o.Artist ?? o.Creator, Album = o.Album, Genre = o.Genre,
            TrackNumber = o.TrackNumber, Year = o.Date is { Length: >= 4 } d && int.TryParse(d[..4], out var y) ? y : null,
            DurationMs = o.DurationMs, FileSize = o.Size, Bitrate = o.Bitrate, SampleRate = o.SampleRate, BitDepth = o.BitsPerSample, Channels = o.Channels,
            Format = ext, Codec = ext.Length > 0 ? AudioFormats.CodecFromExtension("x." + ext) : null, ArtworkUrl = o.AlbumArtUri
        };
    }

    internal static string? MimeToExtension(string? mime) => mime?.ToLowerInvariant() switch
    {
        "audio/flac" or "audio/x-flac" => "flac",
        "audio/mpeg" or "audio/mp3" => "mp3",
        "audio/mp4" or "audio/x-m4a" or "audio/aac" => "m4a",
        "audio/wav" or "audio/x-wav" or "audio/wave" => "wav",
        "audio/l16" => "pcm",
        "audio/ogg" or "audio/x-ogg" or "application/ogg" => "ogg",
        "audio/x-ms-wma" => "wma",
        "audio/x-aiff" or "audio/aiff" => "aiff",
        "audio/x-ape" or "audio/ape" => "ape",
        "audio/x-wavpack" => "wv",
        "audio/x-dsf" or "audio/dsf" => "dsf",
        "audio/opus" => "opus",
        _ => null
    };

    private SourceItem ToItem(DidlObject o)
    {
        if (o.IsContainer)
        {
            var kind = o.UpnpClass switch
            {
                { } c when c.Contains("musicAlbum", StringComparison.OrdinalIgnoreCase) => SourceItemKind.Album,
                { } c when c.Contains("musicArtist", StringComparison.OrdinalIgnoreCase) => SourceItemKind.Artist,
                { } c when c.Contains("genre", StringComparison.OrdinalIgnoreCase) => SourceItemKind.Genre,
                _ => SourceItemKind.Folder
            };
            return FolderItem(UriOf(o.Id), o.Title, kind: kind, artworkUrl: o.AlbumArtUri, childCount: o.ChildCount, subtitle: o.Artist ?? o.Creator);
        }
        var isAudio = o.UpnpClass?.Contains("audioItem", StringComparison.OrdinalIgnoreCase) == true || o.ProtocolInfo?.Contains(":audio/", StringComparison.OrdinalIgnoreCase) == true;
        if (!isAudio) return new SourceItem { Uri = UriOf(o.Id), Name = o.Title, Kind = SourceItemKind.Other, Size = o.Size };
        var t = ToTrack(o);
        return new SourceItem { Uri = t.SourceUri, Name = o.Title, Kind = SourceItemKind.Audio, Size = o.Size, Track = t, ArtworkUrl = o.AlbumArtUri,
            Subtitle = string.Join(" · ", new[] { t.Artist, t.Album }.Where(s => !string.IsNullOrEmpty(s))) };
    }

    public override async Task TestConnectionAsync(CancellationToken ct = default) => await ListAsync(null, ct).ConfigureAwait(false);

    public override async Task<IReadOnlyList<SourceItem>> ListAsync(string? folderUri = null, CancellationToken ct = default) =>
        (await BrowseAsync(IdOf(folderUri), "BrowseDirectChildren", ct).ConfigureAwait(false)).Select(ToItem).ToList();

    public override async Task<IReadOnlyList<SourceItem>> SearchAsync(string query, CancellationToken ct = default)
    {
        var cds = await ContentDirectoryAsync(ct).ConfigureAwait(false);
        var escaped = query.Replace("\\", "\\\\").Replace("\"", "\\\"");
        try
        {
            var resp = await Ssdp.SoapAsync(ctx.Http, cds.ControlUrl, cds.ServiceType, "Search", new[]
            {
                ("ContainerID", "0"), ("SearchCriteria", $"upnp:class derivedfrom \"object.item.audioItem\" and (dc:title contains \"{escaped}\" or upnp:artist contains \"{escaped}\" or upnp:album contains \"{escaped}\")"),
                ("Filter", "*"), ("StartingIndex", "0"), ("RequestedCount", "200"), ("SortCriteria", "")
            }, ct).ConfigureAwait(false);
            _canSearch = true;
            return Didl.Parse(resp.Element("Result")?.Value ?? "").Select(ToItem).ToList();
        }
        catch (SourceException)
        {
            _canSearch = false;
            throw new NotSupportedException($"{Config.Name} does not support search.");
        }
    }

    private async Task<DidlObject> MetaAsync(string uri, CancellationToken ct) =>
        (await BrowseAsync(IdOf(uri), "BrowseMetadata", ct).ConfigureAwait(false)).FirstOrDefault() ?? throw new SourceException("Item not found on media server.");

    public override async Task<Track?> GetTrackAsync(string uri, CancellationToken ct = default)
    {
        try { return ToTrack(await MetaAsync(uri, ct).ConfigureAwait(false)); }
        catch (SourceException) { return null; }
    }

    public override async Task<MediaLocation> ResolveAsync(string uri, CancellationToken ct = default)
    {
        var o = await MetaAsync(uri, ct).ConfigureAwait(false);
        if (string.IsNullOrEmpty(o.ResourceUrl)) throw new SourceException("Item has no playable resource.");
        var t = ToTrack(o);
        return MediaLocation.ForUrl(o.ResourceUrl, null, o.Size > 0 ? o.Size : -1, t.FileName, o.ProtocolInfo?.Split(':').ElementAtOrDefault(2));
    }
}
