using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using MuurMusic.Core.Models;

namespace MuurMusic.Core.Sources;

/// <summary>Shared plumbing for OAuth-based cloud drives: bearer auth with automatic refresh and JSON helpers.</summary>
public abstract class CloudSourceBase(SourceConfig config, SourceContext ctx, string scheme) : MusicSourceBase(config)
{
    protected SourceContext Ctx { get; } = ctx;
    protected string Scheme { get; } = scheme;
    protected abstract string RootId { get; }
    public override string RootUri => SourceUris.ForSourceScoped(Scheme, Config.Id, RootId);

    public override bool Owns(string uri) => SourceUris.TryParseSourceScoped(uri, out var s, out var id, out _) && s == Scheme && id == Config.Id;

    protected string IdOf(string? uri)
    {
        if (uri is null) return RootId;
        return SourceUris.TryParseSourceScoped(uri, out _, out _, out var item) ? (item.Length == 0 ? RootId : item) : throw new SourceException($"Invalid URI {uri}");
    }

    protected string UriOf(string id) => SourceUris.ForSourceScoped(Scheme, Config.Id, id);

    public override async Task TestConnectionAsync(CancellationToken ct = default) => await ListAsync(null, ct).ConfigureAwait(false);

    protected async Task<HttpResponseMessage> SendAsync(Func<HttpRequestMessage> make, CancellationToken ct, HttpCompletionOption completion = HttpCompletionOption.ResponseContentRead, bool auth = true)
    {
        for (var attempt = 0; ; attempt++)
        {
            using var req = make();
            if (auth)
            {
                var token = await Ctx.OAuth.GetTokenAsync(Config, attempt > 0, ct).ConfigureAwait(false);
                AddAuth(req, token);
            }
            HttpResponseMessage resp;
            try { resp = await Ctx.Http.SendAsync(req, completion, ct).ConfigureAwait(false); }
            catch (HttpRequestException ex) { throw new SourceException($"Network error: {ex.Message}", ex); }
            if (resp.StatusCode == HttpStatusCode.Unauthorized && attempt == 0 && auth)
            {
                resp.Dispose();
                continue;
            }
            if ((int)resp.StatusCode == 429 && attempt < 3)
            {
                var wait = resp.Headers.RetryAfter?.Delta ?? TimeSpan.FromSeconds(2 << attempt);
                resp.Dispose();
                await Task.Delay(wait, ct).ConfigureAwait(false);
                continue;
            }
            if (resp.IsSuccessStatusCode || resp.StatusCode is HttpStatusCode.Redirect or HttpStatusCode.Found) return resp;
            var body = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
            var code = (int)resp.StatusCode;
            resp.Dispose();
            var message = ExtractError(body) ?? $"HTTP {code}";
            if (code == 401) throw new SourceAuthenticationException($"{Config.Name}: {message}");
            if (code == 404) throw new SourceException($"Not found ({message})");
            throw new SourceException($"{Config.Name}: {message}");
        }
    }

    protected virtual void AddAuth(HttpRequestMessage req, OAuthToken token) =>
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.AccessToken);

    private static string? ExtractError(string body)
    {
        try
        {
            var n = JsonNode.Parse(body);
            return n?["error_summary"]?.GetValue<string>()
                ?? n?["error"]?["message"]?.GetValue<string>()
                ?? n?["message"]?.GetValue<string>()
                ?? n?["error_description"]?.GetValue<string>()
                ?? n?["error"]?.ToString();
        }
        catch (JsonException) { return body.Length > 0 && body.Length < 200 ? body : null; }
        catch (InvalidOperationException) { return null; }
    }

    protected async Task<JsonNode> JsonAsync(Func<HttpRequestMessage> make, CancellationToken ct)
    {
        using var resp = await SendAsync(make, ct).ConfigureAwait(false);
        var s = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        return s.Length == 0 ? new JsonObject() : JsonNode.Parse(s) ?? new JsonObject();
    }

    protected static HttpRequestMessage Json(HttpMethod method, string url, object? body) =>
        new(method, url) { Content = body is null ? null : JsonContent.Create(body) };

    /// <summary>Opens a GET with a Range header and skips manually if the server ignores it.</summary>
    protected async Task<Stream> OpenRangeAsync(string url, long offset, CancellationToken ct, bool auth = true)
    {
        var resp = await SendAsync(() =>
        {
            var r = new HttpRequestMessage(HttpMethod.Get, url);
            if (offset > 0) r.Headers.Range = new RangeHeaderValue(offset, null);
            return r;
        }, ct, HttpCompletionOption.ResponseHeadersRead, auth).ConfigureAwait(false);
        var body = await resp.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
        if (offset > 0 && resp.StatusCode != HttpStatusCode.PartialContent) await StreamUtil.SkipAsync(body, offset, ct).ConfigureAwait(false);
        return new ResponseStream(body, resp);
    }

    protected static DateTimeOffset? Date(JsonNode? n) =>
        n is not null && DateTimeOffset.TryParse(n.GetValue<string>(), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var d) ? d : null;

    protected static long Long(JsonNode? n)
    {
        if (n is null) return 0;
        var v = n.GetValueKind();
        return v == JsonValueKind.Number ? n.GetValue<long>() : long.TryParse(n.ToString(), out var l) ? l : 0;
    }

    protected static string? Str(JsonNode? n) => n?.GetValueKind() == JsonValueKind.String ? n.GetValue<string>() : n?.ToString();

    protected static readonly string[] AudioExtensionList = AudioFormats.AudioExtensions.Select(e => e.TrimStart('.')).ToArray();
}

/// <summary>Dropbox (API v2). URIs: <c>dropbox://&lt;sourceId&gt;/path/in/dropbox</c>.</summary>
public sealed class DropboxSource(SourceConfig config, SourceContext ctx) : CloudSourceBase(config, ctx, SourceUris.Dropbox)
{
    private const string Api = "https://api.dropboxapi.com/2/";
    private const string Content = "https://content.dropboxapi.com/2/";
    private const long SimpleUploadLimit = 150L * 1024 * 1024;
    private const int ChunkSize = 8 * 1024 * 1024;

    protected override string RootId => "";
    public override SourceCapabilities Capabilities => SourceCapabilities.Browse | SourceCapabilities.Search | SourceCapabilities.Write;

    private string PathOf(string? uri) { var id = IdOf(uri); return id.Length == 0 ? "" : "/" + id.TrimStart('/'); }

    private SourceItem ToItem(JsonNode e)
    {
        var tag = Str(e[".tag"]);
        var path = Str(e["path_display"]) ?? "";
        var name = Str(e["name"]) ?? System.IO.Path.GetFileName(path);
        var uri = UriOf(path);
        return tag == "folder" ? FolderItem(uri, name) : FileItem(uri, name, Long(e["size"]), Date(e["server_modified"]));
    }

    public override async Task<IReadOnlyList<SourceItem>> ListAsync(string? folderUri = null, CancellationToken ct = default)
    {
        var items = new List<SourceItem>();
        var res = await JsonAsync(() => Json(HttpMethod.Post, Api + "files/list_folder", new { path = PathOf(folderUri), limit = 2000 }), ct).ConfigureAwait(false);
        while (true)
        {
            foreach (var e in res["entries"]!.AsArray()) if (e is not null && Str(e[".tag"]) != "deleted") items.Add(ToItem(e));
            if (res["has_more"]?.GetValue<bool>() != true) break;
            var cursor = Str(res["cursor"]);
            res = await JsonAsync(() => Json(HttpMethod.Post, Api + "files/list_folder/continue", new { cursor }), ct).ConfigureAwait(false);
        }
        return Sort(items);
    }

    public override async Task<IReadOnlyList<SourceItem>> SearchAsync(string query, CancellationToken ct = default)
    {
        var res = await JsonAsync(() => Json(HttpMethod.Post, Api + "files/search_v2", new
        {
            query,
            options = new { max_results = 200, file_status = "active", filename_only = false, file_extensions = AudioExtensionList }
        }), ct).ConfigureAwait(false);
        return res["matches"]!.AsArray().Select(m => m?["metadata"]?["metadata"]).Where(m => m is not null).Select(m => ToItem(m!)).ToList();
    }

    public override async Task<MediaLocation> ResolveAsync(string uri, CancellationToken ct = default)
    {
        var path = PathOf(uri);
        var meta = await JsonAsync(() => Json(HttpMethod.Post, Api + "files/get_metadata", new { path }), ct).ConfigureAwait(false);
        var size = Long(meta["size"]);
        return MediaLocation.ForStream(async (offset, token) =>
        {
            var link = await JsonAsync(() => Json(HttpMethod.Post, Api + "files/get_temporary_link", new { path }), token).ConfigureAwait(false);
            return await OpenRangeAsync(Str(link["link"])!, offset, token, auth: false).ConfigureAwait(false);
        }, size, Str(meta["name"]) ?? System.IO.Path.GetFileName(path));
    }

    public override async Task<Track?> GetTrackAsync(string uri, CancellationToken ct = default)
    {
        try
        {
            var meta = await JsonAsync(() => Json(HttpMethod.Post, Api + "files/get_metadata", new { path = PathOf(uri) }), ct).ConfigureAwait(false);
            return CreateFileTrack(uri, Str(meta["name"]) ?? "", Long(meta["size"]), Date(meta["server_modified"]));
        }
        catch (SourceException) { return null; }
    }

    public override async Task<string> CreateFolderAsync(string parentUri, string name, CancellationToken ct = default)
    {
        var path = PathOf(parentUri).TrimEnd('/') + "/" + name;
        var res = await JsonAsync(() => Json(HttpMethod.Post, Api + "files/create_folder_v2", new { path, autorename = true }), ct).ConfigureAwait(false);
        return UriOf(Str(res["metadata"]?["path_display"]) ?? path);
    }

    public override async Task<string> RenameAsync(string uri, string newName, CancellationToken ct = default)
    {
        var from = PathOf(uri);
        var to = from[..(from.LastIndexOf('/') + 1)] + newName;
        var res = await JsonAsync(() => Json(HttpMethod.Post, Api + "files/move_v2", new { from_path = from, to_path = to }), ct).ConfigureAwait(false);
        return UriOf(Str(res["metadata"]?["path_display"]) ?? to);
    }

    public override async Task DeleteAsync(string uri, CancellationToken ct = default) =>
        await JsonAsync(() => Json(HttpMethod.Post, Api + "files/delete_v2", new { path = PathOf(uri) }), ct).ConfigureAwait(false);

    private static HttpRequestMessage ContentRequest(string endpoint, object arg, HttpContent body)
    {
        var req = new HttpRequestMessage(HttpMethod.Post, Content + endpoint) { Content = body };
        // Dropbox-API-Arg must be ASCII; the default serializer escapes non-ASCII characters as \uXXXX.
        req.Headers.TryAddWithoutValidation("Dropbox-API-Arg", JsonSerializer.Serialize(arg));
        body.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        return req;
    }

    public override async Task<string> UploadAsync(string folderUri, string fileName, Stream content, long length, IProgress<long>? progress = null, CancellationToken ct = default)
    {
        var path = PathOf(folderUri).TrimEnd('/') + "/" + fileName;
        if (length >= 0 && length <= SimpleUploadLimit)
        {
            var data = new byte[length];
            await content.ReadExactlyAsync(data, ct).ConfigureAwait(false);
            var res = await JsonAsync(() => ContentRequest("files/upload", new { path, mode = "overwrite", mute = true }, new ByteArrayContent(data)), ct).ConfigureAwait(false);
            progress?.Report(length);
            return UriOf(Str(res["path_display"]) ?? path);
        }
        var buffer = new byte[ChunkSize];
        var n = await ReadChunkAsync(content, buffer, ct).ConfigureAwait(false);
        var first = buffer[..n];
        var start = await JsonAsync(() => ContentRequest("files/upload_session/start", new { close = false }, new ByteArrayContent(first)), ct).ConfigureAwait(false);
        var sessionId = Str(start["session_id"])!;
        long offset = n;
        progress?.Report(offset);
        while (true)
        {
            n = await ReadChunkAsync(content, buffer, ct).ConfigureAwait(false);
            if (n < buffer.Length)
            {
                var last = buffer[..n];
                var at = offset;
                var res = await JsonAsync(() => ContentRequest("files/upload_session/finish",
                    new { cursor = new { session_id = sessionId, offset = at }, commit = new { path, mode = "overwrite", mute = true } }, new ByteArrayContent(last)), ct).ConfigureAwait(false);
                progress?.Report(offset + n);
                return UriOf(Str(res["path_display"]) ?? path);
            }
            var chunk = buffer.ToArray();
            var pos = offset;
            using (await SendAsync(() => ContentRequest("files/upload_session/append_v2", new { cursor = new { session_id = sessionId, offset = pos }, close = false }, new ByteArrayContent(chunk)), ct).ConfigureAwait(false)) { }
            offset += n;
            progress?.Report(offset);
        }
    }

    internal static async Task<int> ReadChunkAsync(Stream s, byte[] buffer, CancellationToken ct)
    {
        var total = 0;
        while (total < buffer.Length)
        {
            var n = await s.ReadAsync(buffer.AsMemory(total), ct).ConfigureAwait(false);
            if (n == 0) break;
            total += n;
        }
        return total;
    }
}

/// <summary>Google Drive (API v3). URIs: <c>gdrive://&lt;sourceId&gt;/&lt;fileId&gt;</c>.</summary>
public sealed class GoogleDriveSource(SourceConfig config, SourceContext ctx) : CloudSourceBase(config, ctx, SourceUris.GDrive)
{
    private const string Api = "https://www.googleapis.com/drive/v3/";
    private const string FolderMime = "application/vnd.google-apps.folder";
    private const string Fields = "nextPageToken,files(id,name,mimeType,size,modifiedTime,thumbnailLink)";

    protected override string RootId => "root";
    public override SourceCapabilities Capabilities => SourceCapabilities.Browse | SourceCapabilities.Search | SourceCapabilities.Write;

    private SourceItem ToItem(JsonNode f)
    {
        var id = Str(f["id"])!;
        var name = Str(f["name"]) ?? id;
        var mime = Str(f["mimeType"]);
        if (mime == FolderMime) return FolderItem(UriOf(id), name, Date(f["modifiedTime"]));
        var item = FileItem(UriOf(id), name, Long(f["size"]), Date(f["modifiedTime"]));
        if (item.Kind == SourceItemKind.Other && mime?.StartsWith("audio/", StringComparison.Ordinal) == true)
            item = item with { Kind = SourceItemKind.Audio, Track = CreateFileTrack(UriOf(id), name, Long(f["size"]), Date(f["modifiedTime"])) };
        return item;
    }

    private async Task<List<SourceItem>> QueryAsync(string q, CancellationToken ct, int max = int.MaxValue)
    {
        var items = new List<SourceItem>();
        string? page = null;
        do
        {
            var url = $"{Api}files?q={Uri.EscapeDataString(q)}&fields={Uri.EscapeDataString(Fields)}&pageSize=1000&supportsAllDrives=true&includeItemsFromAllDrives=true"
                + (page is null ? "" : "&pageToken=" + Uri.EscapeDataString(page));
            var res = await JsonAsync(() => new HttpRequestMessage(HttpMethod.Get, url), ct).ConfigureAwait(false);
            foreach (var f in res["files"]!.AsArray()) if (f is not null && !(Str(f["mimeType"]) ?? "").StartsWith("application/vnd.google-apps.", StringComparison.Ordinal) || Str(f?["mimeType"]) == FolderMime) items.Add(ToItem(f!));
            page = Str(res["nextPageToken"]);
        } while (page is not null && items.Count < max);
        return items;
    }

    private static string Escape(string s) => s.Replace("\\", "\\\\").Replace("'", "\\'");

    public override async Task<IReadOnlyList<SourceItem>> ListAsync(string? folderUri = null, CancellationToken ct = default) =>
        Sort(await QueryAsync($"'{Escape(IdOf(folderUri))}' in parents and trashed = false", ct).ConfigureAwait(false));

    public override async Task<IReadOnlyList<SourceItem>> SearchAsync(string query, CancellationToken ct = default) =>
        await QueryAsync($"name contains '{Escape(query)}' and mimeType contains 'audio/' and trashed = false", ct, 300).ConfigureAwait(false);

    private Task<JsonNode> MetaAsync(string id, CancellationToken ct) =>
        JsonAsync(() => new HttpRequestMessage(HttpMethod.Get, $"{Api}files/{Uri.EscapeDataString(id)}?fields=id,name,mimeType,size,modifiedTime&supportsAllDrives=true"), ct);

    public override async Task<MediaLocation> ResolveAsync(string uri, CancellationToken ct = default)
    {
        var id = IdOf(uri);
        var meta = await MetaAsync(id, ct).ConfigureAwait(false);
        var url = $"{Api}files/{Uri.EscapeDataString(id)}?alt=media&supportsAllDrives=true";
        return MediaLocation.ForStream((offset, token) => OpenRangeAsync(url, offset, token), Long(meta["size"]), Str(meta["name"]) ?? id, Str(meta["mimeType"]));
    }

    public override async Task<Track?> GetTrackAsync(string uri, CancellationToken ct = default)
    {
        try
        {
            var meta = await MetaAsync(IdOf(uri), ct).ConfigureAwait(false);
            return CreateFileTrack(uri, Str(meta["name"]) ?? "", Long(meta["size"]), Date(meta["modifiedTime"]));
        }
        catch (SourceException) { return null; }
    }

    public override async Task<string> CreateFolderAsync(string parentUri, string name, CancellationToken ct = default)
    {
        var res = await JsonAsync(() => Json(HttpMethod.Post, $"{Api}files?supportsAllDrives=true", new { name, mimeType = FolderMime, parents = new[] { IdOf(parentUri) } }), ct).ConfigureAwait(false);
        return UriOf(Str(res["id"])!);
    }

    public override async Task<string> RenameAsync(string uri, string newName, CancellationToken ct = default)
    {
        await JsonAsync(() => Json(HttpMethod.Patch, $"{Api}files/{Uri.EscapeDataString(IdOf(uri))}?supportsAllDrives=true", new { name = newName }), ct).ConfigureAwait(false);
        return uri;
    }

    public override async Task DeleteAsync(string uri, CancellationToken ct = default)
    {
        using var _ = await SendAsync(() => new HttpRequestMessage(HttpMethod.Delete, $"{Api}files/{Uri.EscapeDataString(IdOf(uri))}?supportsAllDrives=true"), ct).ConfigureAwait(false);
    }

    public override async Task<string> UploadAsync(string folderUri, string fileName, Stream content, long length, IProgress<long>? progress = null, CancellationToken ct = default)
    {
        string location;
        using (var init = await SendAsync(() =>
        {
            var r = Json(HttpMethod.Post, "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&supportsAllDrives=true", new { name = fileName, parents = new[] { IdOf(folderUri) } });
            r.Headers.TryAddWithoutValidation("X-Upload-Content-Type", AudioFormats.MimeTypeFromExtension(fileName));
            if (length >= 0) r.Headers.TryAddWithoutValidation("X-Upload-Content-Length", length.ToString(CultureInfo.InvariantCulture));
            return r;
        }, ct).ConfigureAwait(false))
            location = init.Headers.Location?.AbsoluteUri ?? throw new SourceException("Google Drive did not return an upload URL.");
        var res = await JsonAsync(() => new HttpRequestMessage(HttpMethod.Put, location) { Content = new ProgressStreamContent(content, length, progress, AudioFormats.MimeTypeFromExtension(fileName)) }, ct).ConfigureAwait(false);
        return UriOf(Str(res["id"])!);
    }
}

/// <summary>OneDrive personal and business via Microsoft Graph. URIs: <c>onedrive://&lt;sourceId&gt;/&lt;itemId&gt;</c>.</summary>
public sealed class OneDriveSource(SourceConfig config, SourceContext ctx) : CloudSourceBase(config, ctx, SourceUris.OneDrive)
{
    private const string Api = "https://graph.microsoft.com/v1.0/me/drive/";
    private const string Select = "$select=id,name,size,folder,file,audio,lastModifiedDateTime";
    private const int ChunkSize = 320 * 1024 * 32;

    protected override string RootId => "root";
    public override SourceCapabilities Capabilities => SourceCapabilities.Browse | SourceCapabilities.Search | SourceCapabilities.Write;

    private SourceItem ToItem(JsonNode i)
    {
        var id = Str(i["id"])!;
        var name = Str(i["name"]) ?? id;
        var modified = Date(i["lastModifiedDateTime"]);
        if (i["folder"] is { } folder) return FolderItem(UriOf(id), name, modified, childCount: (int?)Long(folder["childCount"]));
        var item = FileItem(UriOf(id), name, Long(i["size"]), modified);
        if (item.Track is { } t && i["audio"] is { } audio)
        {
            t.Title = Str(audio["title"]) ?? t.Title;
            t.Artist = Str(audio["artist"]) ?? t.Artist;
            t.Album = Str(audio["album"]);
            t.AlbumArtist = Str(audio["albumArtist"]);
            t.Genre = Str(audio["genre"]);
            t.Year = audio["year"] is { } y ? (int)Long(y) : null;
            t.TrackNumber = audio["track"] is { } tn ? (int)Long(tn) : t.TrackNumber;
            t.DiscNumber = audio["disc"] is { } dn ? (int)Long(dn) : null;
            t.DurationMs = Long(audio["duration"]);
            t.Bitrate = (int)Long(audio["bitrate"]);
        }
        return item;
    }

    private async Task<List<SourceItem>> PagedAsync(string url, CancellationToken ct, int max = int.MaxValue)
    {
        var items = new List<SourceItem>();
        string? next = url;
        while (next is not null && items.Count < max)
        {
            var u = next;
            var res = await JsonAsync(() => new HttpRequestMessage(HttpMethod.Get, u), ct).ConfigureAwait(false);
            foreach (var i in res["value"]!.AsArray()) if (i is not null) items.Add(ToItem(i));
            next = Str(res["@odata.nextLink"]);
        }
        return items;
    }

    private string ItemPath(string id) => id == "root" ? "root" : "items/" + Uri.EscapeDataString(id);

    public override async Task<IReadOnlyList<SourceItem>> ListAsync(string? folderUri = null, CancellationToken ct = default) =>
        Sort(await PagedAsync($"{Api}{ItemPath(IdOf(folderUri))}/children?$top=999&{Select}", ct).ConfigureAwait(false));

    public override async Task<IReadOnlyList<SourceItem>> SearchAsync(string query, CancellationToken ct = default)
    {
        var all = await PagedAsync($"{Api}root/search(q='{Uri.EscapeDataString(query.Replace("'", "''"))}')?$top=200&{Select}", ct, 400).ConfigureAwait(false);
        return all.Where(i => i.IsPlayable).ToList();
    }

    public override async Task<MediaLocation> ResolveAsync(string uri, CancellationToken ct = default)
    {
        var id = IdOf(uri);
        var meta = await JsonAsync(() => new HttpRequestMessage(HttpMethod.Get, $"{Api}{ItemPath(id)}"), ct).ConfigureAwait(false);
        var name = Str(meta["name"]) ?? id;
        return MediaLocation.ForStream(async (offset, token) =>
        {
            // Download URLs are pre-authenticated and short-lived, so fetch a fresh one per open.
            var fresh = await JsonAsync(() => new HttpRequestMessage(HttpMethod.Get, $"{Api}{ItemPath(id)}"), token).ConfigureAwait(false);
            var url = Str(fresh["@microsoft.graph.downloadUrl"]) ?? throw new SourceException("OneDrive did not return a download URL.");
            return await OpenRangeAsync(url, offset, token, auth: false).ConfigureAwait(false);
        }, Long(meta["size"]), name, Str(meta["file"]?["mimeType"]));
    }

    public override async Task<Track?> GetTrackAsync(string uri, CancellationToken ct = default)
    {
        try
        {
            var meta = await JsonAsync(() => new HttpRequestMessage(HttpMethod.Get, $"{Api}{ItemPath(IdOf(uri))}?{Select}"), ct).ConfigureAwait(false);
            return ToItem(meta).Track;
        }
        catch (SourceException) { return null; }
    }

    public override async Task<string> CreateFolderAsync(string parentUri, string name, CancellationToken ct = default)
    {
        var body = new JsonObject { ["name"] = name, ["folder"] = new JsonObject(), ["@microsoft.graph.conflictBehavior"] = "rename" };
        var res = await JsonAsync(() => new HttpRequestMessage(HttpMethod.Post, $"{Api}{ItemPath(IdOf(parentUri))}/children") { Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json") }, ct).ConfigureAwait(false);
        return UriOf(Str(res["id"])!);
    }

    public override async Task<string> RenameAsync(string uri, string newName, CancellationToken ct = default)
    {
        await JsonAsync(() => Json(HttpMethod.Patch, $"{Api}{ItemPath(IdOf(uri))}", new { name = newName }), ct).ConfigureAwait(false);
        return uri;
    }

    public override async Task DeleteAsync(string uri, CancellationToken ct = default)
    {
        using var _ = await SendAsync(() => new HttpRequestMessage(HttpMethod.Delete, $"{Api}{ItemPath(IdOf(uri))}"), ct).ConfigureAwait(false);
    }

    public override async Task<string> UploadAsync(string folderUri, string fileName, Stream content, long length, IProgress<long>? progress = null, CancellationToken ct = default)
    {
        if (length < 0) throw new SourceException("OneDrive uploads need a known content length.");
        var session = await JsonAsync(() =>
        {
            var body = new JsonObject { ["item"] = new JsonObject { ["@microsoft.graph.conflictBehavior"] = "replace" } };
            return new HttpRequestMessage(HttpMethod.Post, $"{Api}{ItemPath(IdOf(folderUri))}:/{Uri.EscapeDataString(fileName)}:/createUploadSession")
            { Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json") };
        }, ct).ConfigureAwait(false);
        var uploadUrl = Str(session["uploadUrl"])!;
        var buffer = new byte[ChunkSize];
        long offset = 0;
        JsonNode? last = null;
        while (offset < length || length == 0)
        {
            var n = await DropboxSource.ReadChunkAsync(content, buffer, ct).ConfigureAwait(false);
            if (n == 0 && length > 0) throw new EndOfStreamException();
            var chunk = buffer[..n];
            var start = offset;
            last = await JsonAsync(() =>
            {
                var c = new ByteArrayContent(chunk);
                c.Headers.ContentRange = new ContentRangeHeaderValue(start, start + Math.Max(n, 1) - 1, length);
                return new HttpRequestMessage(HttpMethod.Put, uploadUrl) { Content = c };
            }, ct).ConfigureAwait(false);
            offset += n;
            progress?.Report(offset);
            if (length == 0) break;
        }
        return UriOf(Str(last?["id"]) ?? throw new SourceException("Upload did not complete."));
    }
}

/// <summary>Box (API 2.0). URIs: <c>box://&lt;sourceId&gt;/&lt;fileId&gt;</c>; folders use <c>folder:&lt;id&gt;</c>.</summary>
public sealed class BoxSource(SourceConfig config, SourceContext ctx) : CloudSourceBase(config, ctx, SourceUris.Box)
{
    private const string Api = "https://api.box.com/2.0/";
    private const string Upload = "https://upload.box.com/api/2.0/";
    private const string Fields = "fields=id,type,name,size,modified_at";
    private const long ChunkedThreshold = 50L * 1024 * 1024;

    protected override string RootId => "folder:0";
    public override SourceCapabilities Capabilities => SourceCapabilities.Browse | SourceCapabilities.Search | SourceCapabilities.Write;

    private static (bool IsFolder, string Id) Parse(string id) => id.StartsWith("folder:", StringComparison.Ordinal) ? (true, id[7..]) : (false, id);

    private SourceItem ToItem(JsonNode e)
    {
        var id = Str(e["id"])!;
        var name = Str(e["name"]) ?? id;
        return Str(e["type"]) == "folder"
            ? FolderItem(UriOf("folder:" + id), name, Date(e["modified_at"]))
            : FileItem(UriOf(id), name, Long(e["size"]), Date(e["modified_at"]));
    }

    public override async Task<IReadOnlyList<SourceItem>> ListAsync(string? folderUri = null, CancellationToken ct = default)
    {
        var (_, id) = Parse(IdOf(folderUri));
        var items = new List<SourceItem>();
        long offset = 0, total;
        do
        {
            var at = offset;
            var res = await JsonAsync(() => new HttpRequestMessage(HttpMethod.Get, $"{Api}folders/{id}/items?{Fields}&limit=1000&offset={at}"), ct).ConfigureAwait(false);
            var entries = res["entries"]!.AsArray();
            foreach (var e in entries) if (e is not null && Str(e["type"]) is "file" or "folder") items.Add(ToItem(e));
            total = Long(res["total_count"]);
            offset += entries.Count;
            if (entries.Count == 0) break;
        } while (offset < total);
        return Sort(items);
    }

    public override async Task<IReadOnlyList<SourceItem>> SearchAsync(string query, CancellationToken ct = default)
    {
        var res = await JsonAsync(() => new HttpRequestMessage(HttpMethod.Get,
            $"{Api}search?query={Uri.EscapeDataString(query)}&type=file&limit=200&{Fields}&file_extensions={string.Join(',', AudioExtensionList)}"), ct).ConfigureAwait(false);
        return res["entries"]!.AsArray().Where(e => e is not null).Select(e => ToItem(e!)).ToList();
    }

    public override async Task<MediaLocation> ResolveAsync(string uri, CancellationToken ct = default)
    {
        var (_, id) = Parse(IdOf(uri));
        var meta = await JsonAsync(() => new HttpRequestMessage(HttpMethod.Get, $"{Api}files/{id}?{Fields}"), ct).ConfigureAwait(false);
        // The content endpoint redirects to a pre-signed download URL; HttpClient drops the Authorization header on redirect.
        return MediaLocation.ForStream((offset, token) => OpenRangeAsync($"{Api}files/{id}/content", offset, token), Long(meta["size"]), Str(meta["name"]) ?? id);
    }

    public override async Task<Track?> GetTrackAsync(string uri, CancellationToken ct = default)
    {
        try
        {
            var (_, id) = Parse(IdOf(uri));
            var meta = await JsonAsync(() => new HttpRequestMessage(HttpMethod.Get, $"{Api}files/{id}?{Fields}"), ct).ConfigureAwait(false);
            return CreateFileTrack(uri, Str(meta["name"]) ?? id, Long(meta["size"]), Date(meta["modified_at"]));
        }
        catch (SourceException) { return null; }
    }

    public override async Task<string> CreateFolderAsync(string parentUri, string name, CancellationToken ct = default)
    {
        var (_, parent) = Parse(IdOf(parentUri));
        var res = await JsonAsync(() => Json(HttpMethod.Post, $"{Api}folders", new { name, parent = new { id = parent } }), ct).ConfigureAwait(false);
        return UriOf("folder:" + Str(res["id"]));
    }

    public override async Task<string> RenameAsync(string uri, string newName, CancellationToken ct = default)
    {
        var (isFolder, id) = Parse(IdOf(uri));
        await JsonAsync(() => Json(HttpMethod.Put, $"{Api}{(isFolder ? "folders" : "files")}/{id}", new { name = newName }), ct).ConfigureAwait(false);
        return uri;
    }

    public override async Task DeleteAsync(string uri, CancellationToken ct = default)
    {
        var (isFolder, id) = Parse(IdOf(uri));
        using var _ = await SendAsync(() => new HttpRequestMessage(HttpMethod.Delete, isFolder ? $"{Api}folders/{id}?recursive=true" : $"{Api}files/{id}"), ct).ConfigureAwait(false);
    }

    public override async Task<string> UploadAsync(string folderUri, string fileName, Stream content, long length, IProgress<long>? progress = null, CancellationToken ct = default)
    {
        var (_, parent) = Parse(IdOf(folderUri));
        if (length >= 0 && length < ChunkedThreshold)
        {
            var data = new byte[length];
            await content.ReadExactlyAsync(data, ct).ConfigureAwait(false);
            var res = await JsonAsync(() =>
            {
                var form = new MultipartFormDataContent
                {
                    { new StringContent(JsonSerializer.Serialize(new { name = fileName, parent = new { id = parent } })), "attributes" },
                    { new ByteArrayContent(data), "file", fileName }
                };
                return new HttpRequestMessage(HttpMethod.Post, $"{Upload}files/content") { Content = form };
            }, ct).ConfigureAwait(false);
            progress?.Report(length);
            return UriOf(Str(res["entries"]?[0]?["id"])!);
        }
        if (length < 0) throw new SourceException("Box uploads need a known content length.");
        var session = await JsonAsync(() => Json(HttpMethod.Post, $"{Upload}files/upload_sessions", new { folder_id = parent, file_size = length, file_name = fileName }), ct).ConfigureAwait(false);
        var partSize = (int)Long(session["part_size"]);
        var uploadPart = Str(session["session_endpoints"]?["upload_part"])!;
        var commit = Str(session["session_endpoints"]?["commit"])!;
        using var whole = IncrementalHash.CreateHash(HashAlgorithmName.SHA1);
        var parts = new JsonArray();
        var buffer = new byte[partSize];
        long offset = 0;
        while (offset < length)
        {
            var n = await DropboxSource.ReadChunkAsync(content, buffer, ct).ConfigureAwait(false);
            if (n == 0) throw new EndOfStreamException();
            var chunk = buffer[..n];
            whole.AppendData(chunk);
            var digest = Convert.ToBase64String(SHA1.HashData(chunk));
            var start = offset;
            var res = await JsonAsync(() =>
            {
                var c = new ByteArrayContent(chunk);
                c.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
                c.Headers.ContentRange = new ContentRangeHeaderValue(start, start + n - 1, length);
                var r = new HttpRequestMessage(HttpMethod.Put, uploadPart) { Content = c };
                r.Headers.TryAddWithoutValidation("Digest", "sha=" + digest);
                return r;
            }, ct).ConfigureAwait(false);
            parts.Add(res["part"]!.DeepClone());
            offset += n;
            progress?.Report(offset);
        }
        var fileDigest = Convert.ToBase64String(whole.GetHashAndReset());
        for (var attempt = 0; attempt < 10; attempt++)
        {
            using var resp = await SendAsync(() =>
            {
                var r = new HttpRequestMessage(HttpMethod.Post, commit) { Content = new StringContent(new JsonObject { ["parts"] = parts.DeepClone() }.ToJsonString(), Encoding.UTF8, "application/json") };
                r.Headers.TryAddWithoutValidation("Digest", "sha=" + fileDigest);
                return r;
            }, ct).ConfigureAwait(false);
            if (resp.StatusCode == HttpStatusCode.Accepted)
            {
                await Task.Delay(resp.Headers.RetryAfter?.Delta ?? TimeSpan.FromSeconds(2), ct).ConfigureAwait(false);
                continue;
            }
            var json = JsonNode.Parse(await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false));
            return UriOf(Str(json?["entries"]?[0]?["id"])!);
        }
        throw new SourceException("Box did not finish processing the upload.");
    }
}

/// <summary>pCloud (OAuth). URIs: <c>pcloud://&lt;sourceId&gt;/&lt;fileId&gt;</c>; folders use <c>folder:&lt;id&gt;</c>.</summary>
public sealed class PCloudSource(SourceConfig config, SourceContext ctx) : CloudSourceBase(config, ctx, SourceUris.PCloud)
{
    protected override string RootId => "folder:0";
    public override SourceCapabilities Capabilities => SourceCapabilities.Browse | SourceCapabilities.Write;

    private static (bool IsFolder, string Id) Parse(string id) => id.StartsWith("folder:", StringComparison.Ordinal) ? (true, id[7..]) : (false, id);

    private async Task<string> ApiAsync(CancellationToken ct)
    {
        var token = await Ctx.OAuth.GetTokenAsync(Config, false, ct).ConfigureAwait(false);
        return "https://" + token.Extra.GetValueOrDefault("apiHost", "api.pcloud.com") + "/";
    }

    private async Task<JsonNode> CallAsync(string method, string query, CancellationToken ct, HttpContent? body = null)
    {
        var api = await ApiAsync(ct).ConfigureAwait(false);
        var res = await JsonAsync(() => new HttpRequestMessage(body is null ? HttpMethod.Get : HttpMethod.Post, $"{api}{method}?{query}") { Content = body }, ct).ConfigureAwait(false);
        var result = Long(res["result"]);
        if (result != 0)
        {
            var msg = Str(res["error"]) ?? $"error {result}";
            if (result is 1000 or 2000 or 2094 or 2095) throw new SourceAuthenticationException($"pCloud: {msg}");
            throw new SourceException($"pCloud: {msg}");
        }
        return res;
    }

    private SourceItem ToItem(JsonNode m)
    {
        var name = Str(m["name"]) ?? "";
        DateTimeOffset? modified = DateTimeOffset.TryParse(Str(m["modified"]), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var d) ? d : null;
        return m["isfolder"]?.GetValue<bool>() == true
            ? FolderItem(UriOf("folder:" + Long(m["folderid"])), name, modified)
            : FileItem(UriOf(Long(m["fileid"]).ToString(CultureInfo.InvariantCulture)), name, Long(m["size"]), modified);
    }

    public override async Task<IReadOnlyList<SourceItem>> ListAsync(string? folderUri = null, CancellationToken ct = default)
    {
        var (_, id) = Parse(IdOf(folderUri));
        var res = await CallAsync("listfolder", "folderid=" + id, ct).ConfigureAwait(false);
        return Sort(res["metadata"]?["contents"]?.AsArray().Where(m => m is not null).Select(m => ToItem(m!)) ?? Enumerable.Empty<SourceItem>());
    }

    public override async Task<MediaLocation> ResolveAsync(string uri, CancellationToken ct = default)
    {
        var (_, id) = Parse(IdOf(uri));
        var stat = await CallAsync("stat", "fileid=" + id, ct).ConfigureAwait(false);
        var meta = stat["metadata"]!;
        return MediaLocation.ForStream(async (offset, token) =>
        {
            var link = await CallAsync("getfilelink", "fileid=" + id, token).ConfigureAwait(false);
            var url = "https://" + Str(link["hosts"]![0]) + Str(link["path"]);
            return await OpenRangeAsync(url, offset, token, auth: false).ConfigureAwait(false);
        }, Long(meta["size"]), Str(meta["name"]) ?? id, Str(meta["contenttype"]));
    }

    public override async Task<Track?> GetTrackAsync(string uri, CancellationToken ct = default)
    {
        try
        {
            var (_, id) = Parse(IdOf(uri));
            var stat = await CallAsync("stat", "fileid=" + id, ct).ConfigureAwait(false);
            return ToItem(stat["metadata"]!).Track;
        }
        catch (SourceException) { return null; }
    }

    public override async Task<string> CreateFolderAsync(string parentUri, string name, CancellationToken ct = default)
    {
        var (_, parent) = Parse(IdOf(parentUri));
        var res = await CallAsync("createfolder", $"folderid={parent}&name={Uri.EscapeDataString(name)}", ct).ConfigureAwait(false);
        return UriOf("folder:" + Long(res["metadata"]?["folderid"]));
    }

    public override async Task<string> RenameAsync(string uri, string newName, CancellationToken ct = default)
    {
        var (isFolder, id) = Parse(IdOf(uri));
        await CallAsync(isFolder ? "renamefolder" : "renamefile", $"{(isFolder ? "folderid" : "fileid")}={id}&toname={Uri.EscapeDataString(newName)}", ct).ConfigureAwait(false);
        return uri;
    }

    public override async Task DeleteAsync(string uri, CancellationToken ct = default)
    {
        var (isFolder, id) = Parse(IdOf(uri));
        await CallAsync(isFolder ? "deletefolderrecursive" : "deletefile", $"{(isFolder ? "folderid" : "fileid")}={id}", ct).ConfigureAwait(false);
    }

    public override async Task<string> UploadAsync(string folderUri, string fileName, Stream content, long length, IProgress<long>? progress = null, CancellationToken ct = default)
    {
        var (_, parent) = Parse(IdOf(folderUri));
        var form = new MultipartFormDataContent { { new ProgressStreamContent(content, length, progress), "file", fileName } };
        var res = await CallAsync("uploadfile", $"folderid={parent}&filename={Uri.EscapeDataString(fileName)}&nopartial=1", ct, form).ConfigureAwait(false);
        return UriOf(Long(res["metadata"]?[0]?["fileid"]).ToString(CultureInfo.InvariantCulture));
    }

    protected override void AddAuth(HttpRequestMessage req, OAuthToken token) =>
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.AccessToken);
}
