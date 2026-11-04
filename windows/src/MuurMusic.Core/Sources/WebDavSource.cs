using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Xml.Linq;
using MuurMusic.Core.Models;

namespace MuurMusic.Core.Sources;

/// <summary>Known WebDAV providers. <see cref="UrlTemplate"/> may contain {host} and {username}.</summary>
public sealed record WebDavPreset(string Id, string Name, string UrlTemplate, bool NeedsHost, string Notes);

public static class WebDavPresets
{
    public static IReadOnlyList<WebDavPreset> All { get; } = new[]
    {
        new WebDavPreset("custom", "Custom server", "https://{host}/", true, "Enter the full WebDAV URL."),
        new WebDavPreset("nextcloud", "Nextcloud", "https://{host}/remote.php/dav/files/{username}/", true, "Use an app password if two-factor authentication is on."),
        new WebDavPreset("owncloud", "ownCloud", "https://{host}/remote.php/webdav/", true, "Use an app password if two-factor authentication is on."),
        new WebDavPreset("synology", "Synology NAS", "https://{host}:5006/", true, "Enable WebDAV Server (HTTPS port 5006) in Package Center."),
        new WebDavPreset("qnap", "QNAP NAS", "https://{host}:8081/", true, "Enable WebDAV in Control Panel > Web Server (HTTPS port 8081)."),
        new WebDavPreset("yandex", "Yandex Disk", "https://webdav.yandex.ru/", false, "Create an app password at id.yandex.ru."),
        new WebDavPreset("koofr", "Koofr", "https://app.koofr.net/dav/Koofr/", false, "Generate an app password in Koofr preferences."),
        new WebDavPreset("infinicloud", "InfiniCLOUD", "https://{host}/dav/", true, "Host looks like <name>.teracloud.jp; use the Apps Connection password."),
        new WebDavPreset("hidrive", "STRATO HiDrive", "https://webdav.hidrive.strato.com/", false, "WebDAV must be enabled for the HiDrive user."),
        new WebDavPreset("pcloud", "pCloud (US)", "https://webdav.pcloud.com/", false, "Accounts in the US data region."),
        new WebDavPreset("pcloud-eu", "pCloud (EU)", "https://ewebdav.pcloud.com/", false, "Accounts in the EU data region."),
    };

    public static WebDavPreset? Find(string? id) => All.FirstOrDefault(p => string.Equals(p.Id, id, StringComparison.OrdinalIgnoreCase));

    /// <summary>Builds the base URL for a preset.</summary>
    public static string BuildUrl(WebDavPreset preset, string? host, string? username) =>
        preset.UrlTemplate.Replace("{host}", (host ?? "").Trim().TrimEnd('/')).Replace("{username}", Uri.EscapeDataString(username ?? ""));
}

/// <summary>
/// WebDAV source with Basic, Digest or automatic authentication. URIs: <c>webdav(s)://host[:port]/server/path</c>.
/// </summary>
public sealed class WebDavSource : MusicSourceBase
{
    private static readonly XNamespace D = "DAV:";
    private const string PropfindBody = "<?xml version=\"1.0\" encoding=\"utf-8\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:getcontenttype/></d:prop></d:propfind>";

    private readonly SourceContext _ctx;
    private readonly Uri _base;
    private HttpClient? _http;
    private string? _basicHeader;

    public WebDavSource(SourceConfig config, SourceContext ctx) : base(config)
    {
        _ctx = ctx;
        var url = config.Get(SourceKeys.BaseUrl);
        if (url is null && WebDavPresets.Find(config.Get(SourceKeys.Preset)) is { } preset)
            url = WebDavPresets.BuildUrl(preset, config.Get(SourceKeys.Host), config.Get(SourceKeys.Username));
        if (url is null || !Uri.TryCreate(url.EndsWith('/') ? url : url + "/", UriKind.Absolute, out var u) || u.Scheme is not ("http" or "https"))
            throw new SourceException("WebDAV URL is missing or invalid.");
        _base = u;
    }

    private string AuthMode => (Config.Get(SourceKeys.AuthMode) ?? "auto").ToLowerInvariant();
    private string Scheme => _base.Scheme == "https" ? SourceUris.WebDavs : SourceUris.WebDav;
    private int? UriPort => _base.IsDefaultPort ? null : _base.Port;

    public override SourceCapabilities Capabilities => SourceCapabilities.Browse | SourceCapabilities.Write;
    public override string RootUri => UriOfPath(Uri.UnescapeDataString(_base.AbsolutePath));

    public override bool Owns(string uri) =>
        SourceUris.TryParseHost(uri, out var scheme, out var host, out var port, out var path) &&
        scheme == Scheme && host.Equals(_base.Host, StringComparison.OrdinalIgnoreCase) && port == UriPort &&
        path.StartsWith(Uri.UnescapeDataString(_base.AbsolutePath), StringComparison.Ordinal);

    private string UriOfPath(string path) => SourceUris.ForHost(Scheme, _base.Host, UriPort, path);

    private Uri HttpUrlOf(string uri)
    {
        if (!SourceUris.TryParseHost(uri, out _, out _, out _, out var path)) throw new SourceException($"Invalid WebDAV URI: {uri}");
        var port = _base.IsDefaultPort ? "" : ":" + _base.Port;
        return new Uri($"{_base.Scheme}://{_base.Host}{port}/{SourceUris.EscapePath(path.TrimStart('/'))}");
    }

    private async Task<HttpClient> HttpAsync(CancellationToken ct)
    {
        if (_http is not null) return _http;
        var user = Config.Get(SourceKeys.Username);
        var password = await _ctx.SecretAsync(Config, SourceKeys.SecretPassword, ct).ConfigureAwait(false) ?? "";
        ICredentials? creds = null;
        if (user is not null)
        {
            if (AuthMode == "basic")
                _basicHeader = "Basic " + Convert.ToBase64String(Encoding.UTF8.GetBytes(user + ":" + password));
            else
            {
                var cache = new CredentialCache();
                var nc = new NetworkCredential(user, password);
                var root = new Uri(_base.GetLeftPart(UriPartial.Authority));
                cache.Add(root, "Digest", nc);
                if (AuthMode == "auto") cache.Add(root, "Basic", nc);
                creds = cache;
            }
        }
        var client = _ctx.CreateCustomClient(creds, Config.GetBool(SourceKeys.AcceptAnyCertificate), TimeSpan.FromMinutes(30));
        if (_basicHeader is not null) client.DefaultRequestHeaders.TryAddWithoutValidation("Authorization", _basicHeader);
        _http = client;
        return client;
    }

    private async Task<HttpResponseMessage> SendAsync(HttpRequestMessage req, CancellationToken ct, HttpCompletionOption completion = HttpCompletionOption.ResponseContentRead)
    {
        var http = await HttpAsync(ct).ConfigureAwait(false);
        HttpResponseMessage resp;
        try { resp = await http.SendAsync(req, completion, ct).ConfigureAwait(false); }
        catch (HttpRequestException ex) { throw new SourceException($"Cannot reach {_base.Host}: {ex.Message}", ex); }
        if (resp.StatusCode == HttpStatusCode.Unauthorized)
        {
            resp.Dispose();
            throw new SourceAuthenticationException("WebDAV server rejected the username or password.");
        }
        if (!resp.IsSuccessStatusCode && resp.StatusCode != HttpStatusCode.MultiStatus)
        {
            var code = (int)resp.StatusCode;
            resp.Dispose();
            throw new SourceException($"WebDAV {req.Method} failed: HTTP {code}");
        }
        return resp;
    }

    public override async Task TestConnectionAsync(CancellationToken ct = default) => await ListAsync(null, ct).ConfigureAwait(false);

    public override async Task<IReadOnlyList<SourceItem>> ListAsync(string? folderUri = null, CancellationToken ct = default)
    {
        var url = HttpUrlOf(folderUri ?? RootUri);
        var folderPath = Uri.UnescapeDataString(url.AbsolutePath).TrimEnd('/');
        var entries = await PropfindAsync(url, "1", ct).ConfigureAwait(false);
        var items = new List<SourceItem>();
        foreach (var e in entries)
        {
            if (e.Path.TrimEnd('/') == folderPath) continue;
            var name = e.DisplayName ?? System.IO.Path.GetFileName(e.Path.TrimEnd('/'));
            if (name.StartsWith('.')) continue;
            var uri = UriOfPath(e.Path);
            items.Add(e.IsCollection ? FolderItem(uri, name, e.Modified) : FileItem(uri, name, e.Length, e.Modified));
        }
        return Sort(items);
    }

    internal sealed record DavEntry(string Path, string? DisplayName, bool IsCollection, long Length, DateTimeOffset? Modified, string? ContentType);

    private async Task<List<DavEntry>> PropfindAsync(Uri url, string depth, CancellationToken ct)
    {
        using var req = new HttpRequestMessage(new HttpMethod("PROPFIND"), url) { Content = new StringContent(PropfindBody, Encoding.UTF8, "application/xml") };
        req.Headers.Add("Depth", depth);
        using var resp = await SendAsync(req, ct).ConfigureAwait(false);
        var xml = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        return ParseMultistatus(xml);
    }

    internal static List<DavEntry> ParseMultistatus(string xml)
    {
        var doc = XDocument.Parse(xml);
        var list = new List<DavEntry>();
        foreach (var r in doc.Descendants(D + "response"))
        {
            var href = r.Element(D + "href")?.Value;
            if (string.IsNullOrEmpty(href)) continue;
            var path = Uri.TryCreate(href, UriKind.Absolute, out var abs) && abs.Scheme.StartsWith("http") ? abs.AbsolutePath : href;
            path = Uri.UnescapeDataString(path);
            var prop = r.Elements(D + "propstat")
                .Where(ps => (ps.Element(D + "status")?.Value ?? "200").Contains(" 200"))
                .Select(ps => ps.Element(D + "prop")).FirstOrDefault(p => p is not null)
                ?? r.Descendants(D + "prop").FirstOrDefault();
            var isCollection = prop?.Element(D + "resourcetype")?.Element(D + "collection") is not null;
            long.TryParse(prop?.Element(D + "getcontentlength")?.Value, out var length);
            DateTimeOffset? modified = DateTimeOffset.TryParse(prop?.Element(D + "getlastmodified")?.Value, System.Globalization.CultureInfo.InvariantCulture,
                System.Globalization.DateTimeStyles.AssumeUniversal, out var m) ? m : null;
            var display = prop?.Element(D + "displayname")?.Value;
            list.Add(new DavEntry(path, string.IsNullOrWhiteSpace(display) ? null : display, isCollection, length, modified, prop?.Element(D + "getcontenttype")?.Value));
        }
        return list;
    }

    public override async Task<MediaLocation> ResolveAsync(string uri, CancellationToken ct = default)
    {
        var url = HttpUrlOf(uri);
        var entry = (await PropfindAsync(url, "0", ct).ConfigureAwait(false)).FirstOrDefault()
            ?? throw new SourceException($"File not found: {url.AbsolutePath}");
        var name = System.IO.Path.GetFileName(entry.Path);
        await HttpAsync(ct).ConfigureAwait(false);
        // FFmpeg can stream basic-auth URLs directly; digest auth and untrusted certificates go through our own HttpClient.
        if (AuthMode == "basic" && !Config.GetBool(SourceKeys.AcceptAnyCertificate))
        {
            var headers = new Dictionary<string, string>();
            if (_basicHeader is not null) headers["Authorization"] = _basicHeader;
            return MediaLocation.ForUrl(url.AbsoluteUri, headers, entry.Length, name, entry.ContentType);
        }
        return MediaLocation.ForStream(async (offset, token) =>
        {
            var req = new HttpRequestMessage(HttpMethod.Get, url);
            if (offset > 0) req.Headers.Range = new RangeHeaderValue(offset, null);
            var resp = await SendAsync(req, token, HttpCompletionOption.ResponseHeadersRead).ConfigureAwait(false);
            var body = await resp.Content.ReadAsStreamAsync(token).ConfigureAwait(false);
            if (offset > 0 && resp.StatusCode != HttpStatusCode.PartialContent) await StreamUtil.SkipAsync(body, offset, token).ConfigureAwait(false);
            return new ResponseStream(body, resp);
        }, entry.Length, name, entry.ContentType);
    }

    public override async Task<Track?> GetTrackAsync(string uri, CancellationToken ct = default)
    {
        var entry = (await PropfindAsync(HttpUrlOf(uri), "0", ct).ConfigureAwait(false)).FirstOrDefault();
        return entry is null ? null : CreateFileTrack(uri, System.IO.Path.GetFileName(entry.Path), entry.Length, entry.Modified);
    }

    public override async Task<string> CreateFolderAsync(string parentUri, string name, CancellationToken ct = default)
    {
        var target = Child(parentUri, FileSystemSourceBase.SanitizeName(name)) + "/";
        using var req = new HttpRequestMessage(new HttpMethod("MKCOL"), HttpUrlOf(target));
        using var _ = await SendAsync(req, ct).ConfigureAwait(false);
        return target.TrimEnd('/');
    }

    public override async Task<string> RenameAsync(string uri, string newName, CancellationToken ct = default)
    {
        var trimmed = uri.TrimEnd('/');
        var parent = trimmed[..trimmed.LastIndexOf('/')];
        var target = Child(parent, FileSystemSourceBase.SanitizeName(newName));
        using var req = new HttpRequestMessage(new HttpMethod("MOVE"), HttpUrlOf(uri));
        req.Headers.Add("Destination", HttpUrlOf(target).AbsoluteUri);
        req.Headers.Add("Overwrite", "F");
        using var _ = await SendAsync(req, ct).ConfigureAwait(false);
        return target;
    }

    public override async Task DeleteAsync(string uri, CancellationToken ct = default)
    {
        using var req = new HttpRequestMessage(HttpMethod.Delete, HttpUrlOf(uri));
        using var _ = await SendAsync(req, ct).ConfigureAwait(false);
    }

    public override async Task<string> UploadAsync(string folderUri, string fileName, Stream content, long length, IProgress<long>? progress = null, CancellationToken ct = default)
    {
        var target = Child(folderUri, FileSystemSourceBase.SanitizeName(fileName));
        using var req = new HttpRequestMessage(HttpMethod.Put, HttpUrlOf(target)) { Content = new ProgressStreamContent(content, length, progress) };
        using var _ = await SendAsync(req, ct).ConfigureAwait(false);
        return target;
    }

    private static string Child(string folderUri, string name) => folderUri.TrimEnd('/') + "/" + Uri.EscapeDataString(name);

    public override ValueTask DisposeAsync()
    {
        _http?.Dispose();
        _http = null;
        return base.DisposeAsync();
    }
}

/// <summary>HTTP content that streams a body and reports bytes sent.</summary>
internal sealed class ProgressStreamContent : HttpContent
{
    private readonly Stream _content;
    private readonly long _length;
    private readonly IProgress<long>? _progress;

    public ProgressStreamContent(Stream content, long length, IProgress<long>? progress, string mime = "application/octet-stream")
    {
        _content = content;
        _length = length;
        _progress = progress;
        Headers.ContentType = new MediaTypeHeaderValue(mime);
    }

    protected override Task SerializeToStreamAsync(Stream stream, TransportContext? context) => SerializeToStreamAsync(stream, context, CancellationToken.None);

    protected override Task SerializeToStreamAsync(Stream stream, TransportContext? context, CancellationToken ct) =>
        StreamUtil.CopyWithProgressAsync(_content, stream, _progress, ct);

    protected override bool TryComputeLength(out long length)
    {
        length = _length;
        return _length >= 0;
    }
}
