using System.Globalization;
using System.Net;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using MuurMusic.Core.Models;
using MuurMusic.Core.Security;

namespace MuurMusic.Core.Sources;

/// <summary>Helpers shared by media-server sources (Subsonic, Jellyfin/Emby, Plex).</summary>
public abstract class MediaServerSourceBase(SourceConfig config, SourceContext ctx, string scheme) : MusicSourceBase(config)
{
    protected SourceContext Ctx { get; } = ctx;
    protected string Scheme { get; } = scheme;
    public override string RootUri => SourceUris.ForSourceScoped(Scheme, Config.Id, "");
    public override SourceCapabilities Capabilities => SourceCapabilities.Browse | SourceCapabilities.Search | SourceCapabilities.MediaLibrary;
    public override bool Owns(string uri) => SourceUris.TryParseSourceScoped(uri, out var s, out var id, out _) && s == Scheme && id == Config.Id;

    protected string IdOf(string? uri) => uri is null ? "" : SourceUris.TryParseSourceScoped(uri, out _, out _, out var item) ? item : throw new SourceException($"Invalid URI {uri}");
    protected string UriOf(string id) => SourceUris.ForSourceScoped(Scheme, Config.Id, id);

    protected string ServerUrl => (Config.Get(SourceKeys.ServerUrl) ?? Config.Get(SourceKeys.BaseUrl) ?? throw new SourceException("Server URL is not set.")).TrimEnd('/');

    public override async Task TestConnectionAsync(CancellationToken ct = default) => await ListAsync(null, ct).ConfigureAwait(false);

    protected HttpClient Http => Config.GetBool(SourceKeys.AcceptAnyCertificate) ? (_insecure ??= Ctx.CreateCustomClient(null, true)) : Ctx.Http;
    private HttpClient? _insecure;

    protected async Task<JsonNode> GetJsonAsync(string url, CancellationToken ct, Action<HttpRequestMessage>? configure = null, HttpMethod? method = null, HttpContent? content = null)
    {
        using var req = new HttpRequestMessage(method ?? HttpMethod.Get, url) { Content = content };
        req.Headers.Accept.ParseAdd("application/json");
        configure?.Invoke(req);
        HttpResponseMessage resp;
        try { resp = await Http.SendAsync(req, ct).ConfigureAwait(false); }
        catch (HttpRequestException ex) { throw new SourceException($"Cannot reach {Config.Name}: {ex.Message}", ex); }
        using (resp)
        {
            if (resp.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
                throw new SourceAuthenticationException($"{Config.Name} rejected the credentials (HTTP {(int)resp.StatusCode}).");
            if (!resp.IsSuccessStatusCode) throw new SourceException($"{Config.Name}: HTTP {(int)resp.StatusCode}");
            var s = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
            return s.Length == 0 ? new JsonObject() : JsonNode.Parse(s) ?? new JsonObject();
        }
    }

    protected static string? Str(JsonNode? n) => n is null ? null : n.GetValueKind() == System.Text.Json.JsonValueKind.String ? n.GetValue<string>() : n.ToString();
    protected static long Long(JsonNode? n) => n is null ? 0 : n.GetValueKind() == System.Text.Json.JsonValueKind.Number ? (long)n.GetValue<double>() : long.TryParse(n.ToString(), out var l) ? l : 0;
    protected static int? IntN(JsonNode? n) => n is null ? null : (int)Long(n) is var v && v > 0 ? v : null;
    protected static IEnumerable<JsonNode> Arr(JsonNode? n) => n is JsonArray a ? a.Where(x => x is not null)!.Cast<JsonNode>() : n is JsonObject o ? new[] { o } : Enumerable.Empty<JsonNode>();

    protected SourceItem TrackItem(Track t) => new()
    {
        Uri = t.SourceUri, Name = t.DisplayTitle, Kind = SourceItemKind.Audio, Size = t.FileSize, Track = t,
        ArtworkUrl = t.ArtworkUrl, Subtitle = string.Join(" · ", new[] { t.Artist, t.Album }.Where(s => !string.IsNullOrEmpty(s)))
    };

    public override async ValueTask DisposeAsync()
    {
        _insecure?.Dispose();
        await base.DisposeAsync().ConfigureAwait(false);
    }
}

/// <summary>Subsonic / OpenSubsonic servers (Navidrome, Airsonic, Gonic, ...). URIs: <c>subsonic://&lt;sourceId&gt;/&lt;songId&gt;</c>.</summary>
public sealed class SubsonicSource(SourceConfig config, SourceContext ctx) : MediaServerSourceBase(config, ctx, SourceUris.Subsonic)
{
    private const string ApiVersion = "1.16.1";

    private async Task<string> AuthQueryAsync(CancellationToken ct)
    {
        var user = Config.Get(SourceKeys.Username) ?? throw new SourceException("Username is required.");
        var password = await Ctx.SecretAsync(Config, SourceKeys.SecretPassword, ct).ConfigureAwait(false) ?? "";
        string auth;
        if (Config.GetBool(SourceKeys.LegacyAuth))
            auth = "p=enc:" + Convert.ToHexStringLower(Encoding.UTF8.GetBytes(password));
        else
        {
            var salt = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(8));
            var token = Convert.ToHexStringLower(MD5.HashData(Encoding.UTF8.GetBytes(password + salt)));
            auth = $"t={token}&s={salt}";
        }
        return $"u={Uri.EscapeDataString(user)}&{auth}&v={ApiVersion}&c=MuurMusic&f=json";
    }

    internal static string TokenFor(string password, string salt) => Convert.ToHexStringLower(MD5.HashData(Encoding.UTF8.GetBytes(password + salt)));

    private async Task<string> UrlAsync(string method, string query, CancellationToken ct) =>
        $"{ServerUrl}/rest/{method}.view?{await AuthQueryAsync(ct).ConfigureAwait(false)}{(query.Length > 0 ? "&" + query : "")}";

    private async Task<JsonNode> CallAsync(string method, string query, CancellationToken ct)
    {
        var res = await GetJsonAsync(await UrlAsync(method, query, ct).ConfigureAwait(false), ct).ConfigureAwait(false);
        var body = res["subsonic-response"] ?? throw new SourceException("Not a Subsonic server.");
        if (Str(body["status"]) != "ok")
        {
            var code = Long(body["error"]?["code"]);
            var msg = Str(body["error"]?["message"]) ?? "request failed";
            if (code is 40 or 41 or 44) throw new SourceAuthenticationException($"Subsonic: {msg}");
            throw new SourceException($"Subsonic: {msg}");
        }
        return body;
    }

    private async Task<string?> CoverUrlAsync(string? coverId, CancellationToken ct) =>
        coverId is null ? null : await UrlAsync("getCoverArt", "id=" + Uri.EscapeDataString(coverId) + "&size=600", ct).ConfigureAwait(false);

    private async Task<Track> ToTrackAsync(JsonNode s, CancellationToken ct)
    {
        var id = Str(s["id"])!;
        var suffix = Str(s["suffix"]) ?? "";
        return new Track
        {
            SourceUri = UriOf(id), SourceId = Config.Id, IsRemote = true,
            FileName = (Str(s["title"]) ?? id) + (suffix.Length > 0 ? "." + suffix : ""),
            Title = Str(s["title"]), Artist = Str(s["artist"]), Album = Str(s["album"]),
            AlbumArtist = Str(s["albumArtist"]) ?? Str(s["displayAlbumArtist"]),
            Genre = Str(s["genre"]), Year = IntN(s["year"]), TrackNumber = IntN(s["track"]), DiscNumber = IntN(s["discNumber"]),
            DurationMs = Long(s["duration"]) * 1000, Bitrate = (int)Long(s["bitRate"]), FileSize = Long(s["size"]),
            SampleRate = (int)Long(s["samplingRate"]), BitDepth = (int)Long(s["bitDepth"]), Channels = (int)Long(s["channelCount"]),
            Format = suffix.ToLowerInvariant(), Codec = suffix.Length > 0 ? AudioFormats.CodecFromExtension("x." + suffix) : null,
            Rating = (int)Long(s["userRating"]), Favorite = s["starred"] is not null, Bpm = IntN(s["bpm"]),
            ArtworkUrl = await CoverUrlAsync(Str(s["coverArt"]), ct).ConfigureAwait(false),
            MusicBrainzRecordingId = Str(s["musicBrainzId"])
        };
    }

    private async Task<List<SourceItem>> SongsAsync(IEnumerable<JsonNode> songs, CancellationToken ct)
    {
        var list = new List<SourceItem>();
        foreach (var s in songs)
        {
            if (s["isDir"]?.GetValue<bool>() == true) continue;
            list.Add(TrackItem(await ToTrackAsync(s, ct).ConfigureAwait(false)));
        }
        return list;
    }

    private async Task<SourceItem> AlbumItemAsync(JsonNode a, CancellationToken ct) =>
        FolderItem(UriOf("album:" + Str(a["id"])), Str(a["name"]) ?? Str(a["title"]) ?? "", kind: SourceItemKind.Album,
            artworkUrl: await CoverUrlAsync(Str(a["coverArt"]), ct).ConfigureAwait(false),
            subtitle: string.Join(" · ", new[] { Str(a["artist"]), Str(a["year"]) }.Where(x => !string.IsNullOrEmpty(x))), childCount: IntN(a["songCount"]));

    public override async Task<IReadOnlyList<SourceItem>> ListAsync(string? folderUri = null, CancellationToken ct = default)
    {
        var id = IdOf(folderUri);
        var colon = id.IndexOf(':');
        var (kind, arg) = colon < 0 ? (id, "") : (id[..colon], Uri.UnescapeDataString(id[(colon + 1)..]));
        switch (kind)
        {
            case "":
                await CallAsync("ping", "", ct).ConfigureAwait(false);
                return new[]
                {
                    FolderItem(UriOf("artists"), "Artists", kind: SourceItemKind.Library),
                    FolderItem(UriOf("albums"), "Albums", kind: SourceItemKind.Library),
                    FolderItem(UriOf("genres"), "Genres", kind: SourceItemKind.Library),
                    FolderItem(UriOf("playlists"), "Playlists", kind: SourceItemKind.Library),
                    FolderItem(UriOf("folders"), "Folders", kind: SourceItemKind.Library),
                    FolderItem(UriOf("recent"), "Recently added", kind: SourceItemKind.Library),
                    FolderItem(UriOf("starred"), "Starred", kind: SourceItemKind.Library),
                    FolderItem(UriOf("random"), "Random songs", kind: SourceItemKind.Library),
                };
            case "artists":
            {
                var res = await CallAsync("getArtists", "", ct).ConfigureAwait(false);
                return Arr(res["artists"]?["index"]).SelectMany(ix => Arr(ix["artist"]))
                    .Select(a => FolderItem(UriOf("artist:" + Str(a["id"])), Str(a["name"]) ?? "", kind: SourceItemKind.Artist, childCount: IntN(a["albumCount"]))).ToList();
            }
            case "artist":
            {
                var res = await CallAsync("getArtist", "id=" + Uri.EscapeDataString(arg), ct).ConfigureAwait(false);
                var list = new List<SourceItem>();
                foreach (var a in Arr(res["artist"]?["album"])) list.Add(await AlbumItemAsync(a, ct).ConfigureAwait(false));
                return list;
            }
            case "albums":
            case "recent":
            {
                var type = kind == "recent" ? "newest" : "alphabeticalByName";
                var list = new List<SourceItem>();
                for (var offset = 0; offset < (kind == "recent" ? 100 : 5000); offset += 500)
                {
                    var res = await CallAsync("getAlbumList2", $"type={type}&size={(kind == "recent" ? 100 : 500)}&offset={offset}", ct).ConfigureAwait(false);
                    var page = Arr(res["albumList2"]?["album"]).ToList();
                    foreach (var a in page) list.Add(await AlbumItemAsync(a, ct).ConfigureAwait(false));
                    if (page.Count < 500) break;
                }
                return list;
            }
            case "album":
            {
                var res = await CallAsync("getAlbum", "id=" + Uri.EscapeDataString(arg), ct).ConfigureAwait(false);
                return await SongsAsync(Arr(res["album"]?["song"]), ct).ConfigureAwait(false);
            }
            case "genres":
            {
                var res = await CallAsync("getGenres", "", ct).ConfigureAwait(false);
                return Arr(res["genres"]?["genre"]).Select(g => Str(g["value"]) ?? "").Where(g => g.Length > 0).OrderBy(g => g, StringComparer.CurrentCultureIgnoreCase)
                    .Select(g => FolderItem(UriOf("genre:" + Uri.EscapeDataString(g)), g, kind: SourceItemKind.Genre)).ToList();
            }
            case "genre":
            {
                var res = await CallAsync("getSongsByGenre", $"genre={Uri.EscapeDataString(arg)}&count=500", ct).ConfigureAwait(false);
                return await SongsAsync(Arr(res["songsByGenre"]?["song"]), ct).ConfigureAwait(false);
            }
            case "playlists":
            {
                var res = await CallAsync("getPlaylists", "", ct).ConfigureAwait(false);
                return Arr(res["playlists"]?["playlist"]).Select(p => FolderItem(UriOf("playlist:" + Str(p["id"])), Str(p["name"]) ?? "", childCount: IntN(p["songCount"]))).ToList();
            }
            case "playlist":
            {
                var res = await CallAsync("getPlaylist", "id=" + Uri.EscapeDataString(arg), ct).ConfigureAwait(false);
                return await SongsAsync(Arr(res["playlist"]?["entry"]), ct).ConfigureAwait(false);
            }
            case "starred":
            {
                var res = await CallAsync("getStarred2", "", ct).ConfigureAwait(false);
                return await SongsAsync(Arr(res["starred2"]?["song"]), ct).ConfigureAwait(false);
            }
            case "random":
            {
                var res = await CallAsync("getRandomSongs", "size=100", ct).ConfigureAwait(false);
                return await SongsAsync(Arr(res["randomSongs"]?["song"]), ct).ConfigureAwait(false);
            }
            case "folders":
            {
                var res = await CallAsync("getMusicFolders", "", ct).ConfigureAwait(false);
                return Arr(res["musicFolders"]?["musicFolder"]).Select(f => FolderItem(UriOf("index:" + Str(f["id"])), Str(f["name"]) ?? "Music")).ToList();
            }
            case "index":
            {
                var res = await CallAsync("getIndexes", "musicFolderId=" + Uri.EscapeDataString(arg), ct).ConfigureAwait(false);
                var items = Arr(res["indexes"]?["index"]).SelectMany(ix => Arr(ix["artist"]))
                    .Select(a => FolderItem(UriOf("dir:" + Str(a["id"])), Str(a["name"]) ?? "")).ToList();
                items.AddRange(await SongsAsync(Arr(res["indexes"]?["child"]), ct).ConfigureAwait(false));
                return items;
            }
            case "dir":
            {
                var res = await CallAsync("getMusicDirectory", "id=" + Uri.EscapeDataString(arg), ct).ConfigureAwait(false);
                var children = Arr(res["directory"]?["child"]).ToList();
                var items = new List<SourceItem>();
                foreach (var c in children.Where(c => c["isDir"]?.GetValue<bool>() == true))
                    items.Add(FolderItem(UriOf("dir:" + Str(c["id"])), Str(c["title"]) ?? "", artworkUrl: await CoverUrlAsync(Str(c["coverArt"]), ct).ConfigureAwait(false)));
                items.AddRange(await SongsAsync(children, ct).ConfigureAwait(false));
                return items;
            }
            default:
                throw new SourceException($"Unknown Subsonic node {id}");
        }
    }

    public override async Task<IReadOnlyList<SourceItem>> SearchAsync(string query, CancellationToken ct = default)
    {
        var res = await CallAsync("search3", $"query={Uri.EscapeDataString(query)}&artistCount=20&albumCount=40&songCount=200", ct).ConfigureAwait(false);
        var r = res["searchResult3"];
        var items = Arr(r?["artist"]).Select(a => FolderItem(UriOf("artist:" + Str(a["id"])), Str(a["name"]) ?? "", kind: SourceItemKind.Artist)).ToList();
        foreach (var a in Arr(r?["album"])) items.Add(await AlbumItemAsync(a, ct).ConfigureAwait(false));
        items.AddRange(await SongsAsync(Arr(r?["song"]), ct).ConfigureAwait(false));
        return items;
    }

    public override async Task<Track?> GetTrackAsync(string uri, CancellationToken ct = default)
    {
        try
        {
            var res = await CallAsync("getSong", "id=" + Uri.EscapeDataString(IdOf(uri)), ct).ConfigureAwait(false);
            return res["song"] is { } s ? await ToTrackAsync(s, ct).ConfigureAwait(false) : null;
        }
        catch (SourceException ex) when (ex is not SourceAuthenticationException) { return null; }
    }

    public override async Task<MediaLocation> ResolveAsync(string uri, CancellationToken ct = default)
    {
        var id = IdOf(uri);
        var track = await GetTrackAsync(uri, ct).ConfigureAwait(false) ?? throw new SourceException("Song not found on server.");
        var url = await UrlAsync("stream", "id=" + Uri.EscapeDataString(id) + "&format=raw", ct).ConfigureAwait(false);
        return MediaLocation.ForUrl(url, null, track.FileSize > 0 ? track.FileSize : -1, track.FileName);
    }

    /// <summary>Stars/unstars a song on the server.</summary>
    public async Task SetStarredAsync(string uri, bool starred, CancellationToken ct = default) =>
        await CallAsync(starred ? "star" : "unstar", "id=" + Uri.EscapeDataString(IdOf(uri)), ct).ConfigureAwait(false);

    /// <summary>Reports a play to the server (scrobble).</summary>
    public async Task ScrobbleAsync(string uri, bool submission, CancellationToken ct = default) =>
        await CallAsync("scrobble", $"id={Uri.EscapeDataString(IdOf(uri))}&submission={(submission ? "true" : "false")}", ct).ConfigureAwait(false);
}

/// <summary>Jellyfin and Emby servers. URIs: <c>jellyfin://&lt;sourceId&gt;/&lt;itemId&gt;</c> / <c>emby://...</c>.</summary>
public sealed class JellyfinSource(SourceConfig config, SourceContext ctx) : MediaServerSourceBase(config, ctx, config.Kind == SourceKind.Emby ? SourceUris.Emby : SourceUris.Jellyfin)
{
    private const string TrackFields = "Fields=MediaSources,Genres,ProductionYear,ParentId,DateCreated&EnableImageTypes=Primary";
    private string? _token;
    private string? _userId;

    private string AuthHeader(string? token) =>
        $"MediaBrowser Client=\"MuurMusic\", Device=\"Windows\", DeviceId=\"{Config.Id:N}\", Version=\"1.0.0\"" + (token is null ? "" : $", Token=\"{token}\"");

    private async Task<(string Token, string UserId)> SessionAsync(CancellationToken ct, bool force = false)
    {
        if (!force && _token is not null && _userId is not null) return (_token, _userId);
        if (!force && await Ctx.SecretAsync(Config, SourceKeys.SecretToken, ct).ConfigureAwait(false) is { Length: > 0 } stored && Config.Get(SourceKeys.UserId) is { } uid)
        {
            _token = stored;
            _userId = uid;
            return (stored, uid);
        }
        var user = Config.Get(SourceKeys.Username) ?? throw new SourceException("Username is required.");
        var password = await Ctx.SecretAsync(Config, SourceKeys.SecretPassword, ct).ConfigureAwait(false) ?? "";
        var res = await GetJsonAsync($"{ServerUrl}/Users/AuthenticateByName", ct, r =>
        {
            r.Headers.TryAddWithoutValidation("X-Emby-Authorization", AuthHeader(null));
            r.Headers.TryAddWithoutValidation("Authorization", AuthHeader(null));
        }, HttpMethod.Post, JsonContent.Create(new { Username = user, Pw = password, Password = password })).ConfigureAwait(false);
        _token = Str(res["AccessToken"]) ?? throw new SourceAuthenticationException("Login failed.");
        _userId = Str(res["User"]?["Id"]) ?? throw new SourceAuthenticationException("Login failed.");
        await Ctx.Credentials.SetSourceSecretAsync(Config.Id, SourceKeys.SecretToken, _token, ct).ConfigureAwait(false);
        Config.Set(SourceKeys.UserId, _userId);
        return (_token, _userId);
    }

    private async Task<JsonNode> ApiAsync(string pathAndQuery, CancellationToken ct)
    {
        for (var attempt = 0; ; attempt++)
        {
            var (token, _) = await SessionAsync(ct, attempt > 0).ConfigureAwait(false);
            try
            {
                return await GetJsonAsync($"{ServerUrl}{pathAndQuery}", ct, r =>
                {
                    r.Headers.TryAddWithoutValidation("X-Emby-Token", token);
                    r.Headers.TryAddWithoutValidation("X-Emby-Authorization", AuthHeader(token));
                }).ConfigureAwait(false);
            }
            catch (SourceAuthenticationException) when (attempt == 0) { _token = null; }
        }
    }

    private string ImageUrl(string itemId, string? tag) =>
        $"{ServerUrl}/Items/{itemId}/Images/Primary?maxHeight=600&quality=90" + (tag is null ? "" : "&tag=" + tag);

    private Track ToTrack(JsonNode i)
    {
        var id = Str(i["Id"])!;
        var source = Arr(i["MediaSources"]).FirstOrDefault();
        var stream = Arr(source?["MediaStreams"]).FirstOrDefault(s => Str(s["Type"]) == "Audio");
        var container = Str(source?["Container"]) ?? Str(i["Container"]) ?? "";
        var albumId = Str(i["AlbumId"]);
        var imageTag = Str(i["ImageTags"]?["Primary"]);
        var codec = Str(stream?["Codec"]);
        return new Track
        {
            SourceUri = UriOf(id), SourceId = Config.Id, IsRemote = true,
            FileName = (Str(i["Name"]) ?? id) + (container.Length > 0 ? "." + container.Split(',')[0] : ""),
            Title = Str(i["Name"]), Artist = string.Join("; ", Arr(i["Artists"]).Select(a => a.ToString())) is { Length: > 0 } ar ? ar : Str(i["AlbumArtist"]),
            Album = Str(i["Album"]), AlbumArtist = Str(i["AlbumArtist"]), Genre = string.Join("; ", Arr(i["Genres"]).Select(g => g.ToString())) is { Length: > 0 } g ? g : null,
            Year = IntN(i["ProductionYear"]), TrackNumber = IntN(i["IndexNumber"]), DiscNumber = IntN(i["ParentIndexNumber"]),
            DurationMs = Long(i["RunTimeTicks"]) / 10_000, FileSize = Long(source?["Size"]), Bitrate = (int)(Long(source?["Bitrate"]) / 1000),
            SampleRate = (int)Long(stream?["SampleRate"]), BitDepth = (int)Long(stream?["BitDepth"]), Channels = (int)Long(stream?["Channels"]),
            Format = container.Split(',')[0].ToLowerInvariant(), Codec = codec is null ? null : codec.ToUpperInvariant() switch { "FLAC" => "FLAC", "ALAC" => "ALAC", "MP3" => "MP3", "AAC" => "AAC", "VORBIS" => "Vorbis", "OPUS" => "Opus", var c => c },
            Favorite = i["UserData"]?["IsFavorite"]?.GetValue<bool>() == true, PlayCount = (int)Long(i["UserData"]?["PlayCount"]),
            ArtworkUrl = imageTag is not null ? ImageUrl(id, imageTag) : albumId is not null && Str(i["AlbumPrimaryImageTag"]) is { } at ? ImageUrl(albumId, at) : null
        };
    }

    private SourceItem ToItem(JsonNode i)
    {
        var type = Str(i["Type"]);
        var id = Str(i["Id"])!;
        var name = Str(i["Name"]) ?? "";
        var art = Str(i["ImageTags"]?["Primary"]) is { } tag ? ImageUrl(id, tag) : null;
        return type switch
        {
            "Audio" => TrackItem(ToTrack(i)),
            "MusicAlbum" => FolderItem(UriOf("album:" + id), name, kind: SourceItemKind.Album, artworkUrl: art,
                subtitle: string.Join(" · ", new[] { Str(i["AlbumArtist"]), Str(i["ProductionYear"]) }.Where(s => !string.IsNullOrEmpty(s))), childCount: IntN(i["ChildCount"])),
            "MusicArtist" => FolderItem(UriOf("artist:" + id), name, kind: SourceItemKind.Artist, artworkUrl: art),
            "MusicGenre" or "Genre" => FolderItem(UriOf("genre:" + id), name, kind: SourceItemKind.Genre),
            "Playlist" => FolderItem(UriOf("playlist:" + id), name, artworkUrl: art, childCount: IntN(i["ChildCount"])),
            _ => FolderItem(UriOf("folder:" + id), name, artworkUrl: art)
        };
    }

    private async Task<List<SourceItem>> ItemsAsync(string query, CancellationToken ct)
    {
        var (_, uid) = await SessionAsync(ct).ConfigureAwait(false);
        var res = await ApiAsync($"/Users/{uid}/Items?{query}&{TrackFields}", ct).ConfigureAwait(false);
        return Arr(res["Items"]).Select(ToItem).ToList();
    }

    public override async Task<IReadOnlyList<SourceItem>> ListAsync(string? folderUri = null, CancellationToken ct = default)
    {
        var id = IdOf(folderUri);
        var colon = id.IndexOf(':');
        var (kind, arg) = colon < 0 ? (id, "") : (id[..colon], id[(colon + 1)..]);
        var (_, uid) = await SessionAsync(ct).ConfigureAwait(false);
        switch (kind)
        {
            case "":
                return new[]
                {
                    FolderItem(UriOf("artists"), "Artists", kind: SourceItemKind.Library),
                    FolderItem(UriOf("albums"), "Albums", kind: SourceItemKind.Library),
                    FolderItem(UriOf("genres"), "Genres", kind: SourceItemKind.Library),
                    FolderItem(UriOf("playlists"), "Playlists", kind: SourceItemKind.Library),
                    FolderItem(UriOf("libraries"), "Libraries", kind: SourceItemKind.Library),
                    FolderItem(UriOf("recent"), "Recently added", kind: SourceItemKind.Library),
                    FolderItem(UriOf("favorites"), "Favorites", kind: SourceItemKind.Library),
                };
            case "artists":
            {
                var res = await ApiAsync($"/Artists/AlbumArtists?UserId={uid}&Recursive=true&SortBy=SortName&SortOrder=Ascending&EnableImageTypes=Primary", ct).ConfigureAwait(false);
                return Arr(res["Items"]).Select(ToItem).ToList();
            }
            case "artist":
                return await ItemsAsync($"AlbumArtistIds={arg}&IncludeItemTypes=MusicAlbum&Recursive=true&SortBy=ProductionYear,SortName", ct).ConfigureAwait(false);
            case "albums":
                return await ItemsAsync("IncludeItemTypes=MusicAlbum&Recursive=true&SortBy=AlbumArtist,SortName", ct).ConfigureAwait(false);
            case "recent":
                return await ItemsAsync("IncludeItemTypes=MusicAlbum&Recursive=true&SortBy=DateCreated&SortOrder=Descending&Limit=100", ct).ConfigureAwait(false);
            case "favorites":
                return await ItemsAsync("IncludeItemTypes=Audio&Recursive=true&Filters=IsFavorite&SortBy=AlbumArtist,Album,ParentIndexNumber,IndexNumber", ct).ConfigureAwait(false);
            case "album":
                return await ItemsAsync($"ParentId={arg}&SortBy=ParentIndexNumber,IndexNumber,SortName", ct).ConfigureAwait(false);
            case "genres":
            {
                var res = await ApiAsync($"/MusicGenres?UserId={uid}&Recursive=true&SortBy=SortName", ct).ConfigureAwait(false);
                return Arr(res["Items"]).Select(ToItem).ToList();
            }
            case "genre":
                return await ItemsAsync($"GenreIds={arg}&IncludeItemTypes=MusicAlbum&Recursive=true&SortBy=SortName", ct).ConfigureAwait(false);
            case "playlists":
                return await ItemsAsync("IncludeItemTypes=Playlist&Recursive=true&SortBy=SortName", ct).ConfigureAwait(false);
            case "playlist":
            {
                var res = await ApiAsync($"/Playlists/{arg}/Items?UserId={uid}&{TrackFields}", ct).ConfigureAwait(false);
                return Arr(res["Items"]).Select(ToItem).ToList();
            }
            case "libraries":
            {
                var res = await ApiAsync($"/Users/{uid}/Views", ct).ConfigureAwait(false);
                return Arr(res["Items"]).Where(v => Str(v["CollectionType"]) is "music" or null).Select(v => FolderItem(UriOf("folder:" + Str(v["Id"])), Str(v["Name"]) ?? "")).ToList();
            }
            case "folder":
                return await ItemsAsync($"ParentId={arg}&SortBy=IsFolder,SortName", ct).ConfigureAwait(false);
            default:
                throw new SourceException($"Unknown node {id}");
        }
    }

    public override async Task<IReadOnlyList<SourceItem>> SearchAsync(string query, CancellationToken ct = default) =>
        await ItemsAsync($"searchTerm={Uri.EscapeDataString(query)}&IncludeItemTypes=MusicArtist,MusicAlbum,Audio&Recursive=true&Limit=200", ct).ConfigureAwait(false);

    public override async Task<Track?> GetTrackAsync(string uri, CancellationToken ct = default)
    {
        var (_, uid) = await SessionAsync(ct).ConfigureAwait(false);
        try
        {
            var res = await ApiAsync($"/Users/{uid}/Items/{IdOf(uri)}?{TrackFields}", ct).ConfigureAwait(false);
            return ToTrack(res);
        }
        catch (SourceException ex) when (ex is not SourceAuthenticationException) { return null; }
    }

    public override async Task<MediaLocation> ResolveAsync(string uri, CancellationToken ct = default)
    {
        var track = await GetTrackAsync(uri, ct).ConfigureAwait(false) ?? throw new SourceException("Item not found on server.");
        var (token, _) = await SessionAsync(ct).ConfigureAwait(false);
        var url = $"{ServerUrl}/Audio/{IdOf(uri)}/stream?static=true&api_key={Uri.EscapeDataString(token)}";
        return MediaLocation.ForUrl(url, new Dictionary<string, string> { ["X-Emby-Token"] = token }, track.FileSize > 0 ? track.FileSize : -1, track.FileName);
    }

    /// <summary>Reports playback start/stop so the server tracks play counts.</summary>
    public async Task ReportPlayedAsync(string uri, CancellationToken ct = default)
    {
        var (token, uid) = await SessionAsync(ct).ConfigureAwait(false);
        await GetJsonAsync($"{ServerUrl}/Users/{uid}/PlayedItems/{IdOf(uri)}", ct, r => r.Headers.TryAddWithoutValidation("X-Emby-Token", token), HttpMethod.Post).ConfigureAwait(false);
    }
}

/// <summary>A Plex Media Server returned by plex.tv resources.</summary>
public sealed record PlexServer(string Name, string ClientIdentifier, string AccessToken, IReadOnlyList<PlexConnection> Connections, bool Owned);
public sealed record PlexConnection(string Uri, bool Local, bool Relay);
/// <summary>PIN created for the Plex sign-in flow; open <see cref="AuthUrl"/> in the browser and poll.</summary>
public sealed record PlexPin(long Id, string Code, string AuthUrl, string ClientIdentifier);

/// <summary>plex.tv PIN authentication and server discovery.</summary>
public sealed class PlexAuthService(IHttpClientFactory httpFactory)
{
    private const string Product = "MuurMusic";

    private HttpRequestMessage Request(HttpMethod method, string url, string clientId, string? token = null)
    {
        var r = new HttpRequestMessage(method, url);
        r.Headers.Accept.ParseAdd("application/json");
        r.Headers.TryAddWithoutValidation("X-Plex-Product", Product);
        r.Headers.TryAddWithoutValidation("X-Plex-Client-Identifier", clientId);
        r.Headers.TryAddWithoutValidation("X-Plex-Device", "Windows");
        r.Headers.TryAddWithoutValidation("X-Plex-Platform", "Windows");
        r.Headers.TryAddWithoutValidation("X-Plex-Version", "1.0.0");
        if (token is not null) r.Headers.TryAddWithoutValidation("X-Plex-Token", token);
        return r;
    }

    private async Task<JsonNode> SendAsync(HttpRequestMessage req, CancellationToken ct)
    {
        using (req)
        {
            using var resp = await httpFactory.CreateClient(HttpClientNames.Default).SendAsync(req, ct).ConfigureAwait(false);
            if (resp.StatusCode == HttpStatusCode.Unauthorized) throw new SourceAuthenticationException("Plex rejected the sign-in.");
            if (!resp.IsSuccessStatusCode) throw new SourceException($"plex.tv: HTTP {(int)resp.StatusCode}");
            return JsonNode.Parse(await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false)) ?? new JsonObject();
        }
    }

    /// <param name="clientIdentifier">Stable id for this app install/source (e.g. the source id).</param>
    public async Task<PlexPin> CreatePinAsync(string clientIdentifier, CancellationToken ct = default)
    {
        var res = await SendAsync(Request(HttpMethod.Post, "https://plex.tv/api/v2/pins?strong=true", clientIdentifier), ct).ConfigureAwait(false);
        var id = res["id"]!.GetValue<long>();
        var code = res["code"]!.GetValue<string>();
        var url = "https://app.plex.tv/auth#?clientID=" + Uri.EscapeDataString(clientIdentifier) + "&code=" + Uri.EscapeDataString(code)
            + "&context%5Bdevice%5D%5Bproduct%5D=" + Product;
        return new PlexPin(id, code, url, clientIdentifier);
    }

    /// <summary>Returns the auth token once the user approved the PIN, otherwise null.</summary>
    public async Task<string?> CheckPinAsync(PlexPin pin, CancellationToken ct = default)
    {
        var res = await SendAsync(Request(HttpMethod.Get, $"https://plex.tv/api/v2/pins/{pin.Id}", pin.ClientIdentifier), ct).ConfigureAwait(false);
        return res["authToken"]?.GetValueKind() == System.Text.Json.JsonValueKind.String && res["authToken"]!.GetValue<string>() is { Length: > 0 } t ? t : null;
    }

    /// <summary>Polls the PIN every 2 s until approved, expired (15 min) or canceled.</summary>
    public async Task<string> WaitForPinAsync(PlexPin pin, CancellationToken ct = default)
    {
        var deadline = DateTimeOffset.UtcNow.AddMinutes(15);
        while (DateTimeOffset.UtcNow < deadline)
        {
            if (await CheckPinAsync(pin, ct).ConfigureAwait(false) is { } token) return token;
            await Task.Delay(2000, ct).ConfigureAwait(false);
        }
        throw new SourceAuthenticationException("The Plex sign-in PIN expired.");
    }

    public async Task<IReadOnlyList<PlexServer>> GetServersAsync(string userToken, string clientIdentifier, CancellationToken ct = default)
    {
        var res = await SendAsync(Request(HttpMethod.Get, "https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1", clientIdentifier, userToken), ct).ConfigureAwait(false);
        var list = new List<PlexServer>();
        foreach (var r in res.AsArray())
        {
            if (r is null || !(r["provides"]?.GetValue<string>() ?? "").Contains("server", StringComparison.Ordinal)) continue;
            var conns = (r["connections"] as JsonArray ?? new JsonArray()).Where(c => c is not null)
                .Select(c => new PlexConnection(c!["uri"]!.GetValue<string>(), c["local"]?.GetValue<bool>() == true, c["relay"]?.GetValue<bool>() == true)).ToList();
            list.Add(new PlexServer(r["name"]?.GetValue<string>() ?? "Plex", r["clientIdentifier"]?.GetValue<string>() ?? "",
                r["accessToken"]?.GetValue<string>() ?? userToken, conns, r["owned"]?.GetValue<bool>() == true));
        }
        return list;
    }

    /// <summary>Picks the first reachable connection (local first, relay last).</summary>
    public async Task<string?> PickConnectionAsync(PlexServer server, CancellationToken ct = default)
    {
        var http = httpFactory.CreateClient(HttpClientNames.Default);
        foreach (var c in server.Connections.OrderBy(c => c.Relay).ThenByDescending(c => c.Local))
        {
            try
            {
                using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
                cts.CancelAfter(TimeSpan.FromSeconds(4));
                using var req = Request(HttpMethod.Get, c.Uri.TrimEnd('/') + "/identity", server.ClientIdentifier, server.AccessToken);
                using var resp = await http.SendAsync(req, cts.Token).ConfigureAwait(false);
                if (resp.IsSuccessStatusCode) return c.Uri.TrimEnd('/');
            }
            catch (Exception ex) when (ex is HttpRequestException or OperationCanceledException && !ct.IsCancellationRequested) { }
        }
        return null;
    }

    /// <summary>Fills a Plex source config (server URL/id) and returns the token to store as <see cref="SourceKeys.SecretToken"/>.</summary>
    public async Task<string> ConfigureSourceAsync(SourceConfig config, PlexServer server, CancellationToken ct = default)
    {
        var url = await PickConnectionAsync(server, ct).ConfigureAwait(false) ?? throw new SourceException($"{server.Name} is not reachable.");
        config.Set(SourceKeys.ServerUrl, url).Set(SourceKeys.ServerId, server.ClientIdentifier);
        if (string.IsNullOrEmpty(config.Name)) config.Name = server.Name;
        return server.AccessToken;
    }
}

/// <summary>Plex Media Server music libraries. URIs: <c>plex://&lt;sourceId&gt;/&lt;ratingKey&gt;</c>.</summary>
public sealed class PlexSource(SourceConfig config, SourceContext ctx) : MediaServerSourceBase(config, ctx, SourceUris.Plex)
{
    private async Task<string> TokenAsync(CancellationToken ct) =>
        await Ctx.SecretAsync(Config, SourceKeys.SecretToken, ct).ConfigureAwait(false) ?? throw new SourceAuthenticationException("Plex is not signed in.");

    private async Task<JsonNode> ApiAsync(string path, CancellationToken ct)
    {
        var token = await TokenAsync(ct).ConfigureAwait(false);
        var res = await GetJsonAsync(ServerUrl + path, ct, r =>
        {
            r.Headers.TryAddWithoutValidation("X-Plex-Token", token);
            r.Headers.TryAddWithoutValidation("X-Plex-Client-Identifier", Config.Id.ToString("N"));
            r.Headers.TryAddWithoutValidation("X-Plex-Product", "MuurMusic");
        }).ConfigureAwait(false);
        return res["MediaContainer"] ?? new JsonObject();
    }

    private async Task<string?> ArtAsync(string? thumb, CancellationToken ct) =>
        thumb is null ? null : $"{ServerUrl}/photo/:/transcode?width=600&height=600&minSize=1&url={Uri.EscapeDataString(thumb)}&X-Plex-Token={Uri.EscapeDataString(await TokenAsync(ct).ConfigureAwait(false))}";

    private async Task<Track> ToTrackAsync(JsonNode m, CancellationToken ct)
    {
        var media = Arr(m["Media"]).FirstOrDefault();
        var part = Arr(media?["Part"]).FirstOrDefault();
        var stream = Arr(part?["Stream"]).FirstOrDefault(s => Long(s["streamType"]) == 2);
        var container = Str(media?["container"]) ?? Str(part?["container"]) ?? "";
        var codec = Str(media?["audioCodec"]);
        return new Track
        {
            SourceUri = UriOf(Str(m["ratingKey"])!), SourceId = Config.Id, IsRemote = true,
            FileName = Path.GetFileName(Str(part?["file"]) ?? (Str(m["title"]) + "." + container)),
            Title = Str(m["title"]), Artist = Str(m["originalTitle"]) ?? Str(m["grandparentTitle"]), AlbumArtist = Str(m["grandparentTitle"]),
            Album = Str(m["parentTitle"]), Year = IntN(m["parentYear"]) ?? IntN(m["year"]), TrackNumber = IntN(m["index"]), DiscNumber = IntN(m["parentIndex"]),
            Genre = string.Join("; ", Arr(m["Genre"]).Select(g => Str(g["tag"]))) is { Length: > 0 } g ? g : null,
            DurationMs = Long(m["duration"]), Bitrate = (int)Long(media?["bitrate"]), Channels = (int)Long(media?["audioChannels"]),
            SampleRate = (int)Long(stream?["samplingRate"]), BitDepth = (int)Long(stream?["bitDepth"]), FileSize = Long(part?["size"]),
            Format = container.ToLowerInvariant(), Codec = codec?.ToUpperInvariant() switch { null => null, "VORBIS" => "Vorbis", "OPUS" => "Opus", var c => c },
            Rating = (int)Math.Round(Long(m["userRating"]) / 2.0), PlayCount = (int)Long(m["viewCount"]),
            ArtworkUrl = await ArtAsync(Str(m["thumb"]) ?? Str(m["parentThumb"]), ct).ConfigureAwait(false)
        };
    }

    private async Task<List<SourceItem>> ItemsAsync(JsonNode container, CancellationToken ct)
    {
        var list = new List<SourceItem>();
        foreach (var m in Arr(container["Metadata"]).Concat(Arr(container["Directory"])))
        {
            var type = Str(m["type"]);
            var key = Str(m["ratingKey"]) ?? Str(m["key"]);
            var title = Str(m["title"]) ?? "";
            switch (type)
            {
                case "track": list.Add(TrackItem(await ToTrackAsync(m, ct).ConfigureAwait(false))); break;
                case "album":
                    list.Add(FolderItem(UriOf("album:" + key), title, kind: SourceItemKind.Album, artworkUrl: await ArtAsync(Str(m["thumb"]), ct).ConfigureAwait(false),
                        subtitle: string.Join(" · ", new[] { Str(m["parentTitle"]), Str(m["year"]) }.Where(s => !string.IsNullOrEmpty(s))), childCount: IntN(m["leafCount"])));
                    break;
                case "artist":
                    list.Add(FolderItem(UriOf("artist:" + key), title, kind: SourceItemKind.Artist, artworkUrl: await ArtAsync(Str(m["thumb"]), ct).ConfigureAwait(false)));
                    break;
                case "playlist":
                    list.Add(FolderItem(UriOf("playlist:" + key), title, childCount: IntN(m["leafCount"])));
                    break;
            }
        }
        return list;
    }

    public override async Task<IReadOnlyList<SourceItem>> ListAsync(string? folderUri = null, CancellationToken ct = default)
    {
        var id = IdOf(folderUri);
        var colon = id.IndexOf(':');
        var (kind, arg) = colon < 0 ? (id, "") : (id[..colon], id[(colon + 1)..]);
        switch (kind)
        {
            case "":
            {
                var res = await ApiAsync("/library/sections", ct).ConfigureAwait(false);
                var items = Arr(res["Directory"]).Where(d => Str(d["type"]) == "artist")
                    .Select(d => FolderItem(UriOf("section:" + Str(d["key"])), Str(d["title"]) ?? "Music", kind: SourceItemKind.Library)).ToList();
                items.Add(FolderItem(UriOf("playlists"), "Playlists", kind: SourceItemKind.Library));
                return items;
            }
            case "section":
                return new[]
                {
                    FolderItem(UriOf("sartists:" + arg), "Artists", kind: SourceItemKind.Library),
                    FolderItem(UriOf("salbums:" + arg), "Albums", kind: SourceItemKind.Library),
                    FolderItem(UriOf("srecent:" + arg), "Recently added", kind: SourceItemKind.Library),
                    FolderItem(UriOf("sgenres:" + arg), "Genres", kind: SourceItemKind.Library),
                };
            case "sartists": return await ItemsAsync(await ApiAsync($"/library/sections/{arg}/all?type=8", ct).ConfigureAwait(false), ct).ConfigureAwait(false);
            case "salbums": return await ItemsAsync(await ApiAsync($"/library/sections/{arg}/all?type=9", ct).ConfigureAwait(false), ct).ConfigureAwait(false);
            case "srecent": return await ItemsAsync(await ApiAsync($"/library/sections/{arg}/recentlyAdded?type=9&X-Plex-Container-Start=0&X-Plex-Container-Size=100", ct).ConfigureAwait(false), ct).ConfigureAwait(false);
            case "sgenres":
            {
                var res = await ApiAsync($"/library/sections/{arg}/genre", ct).ConfigureAwait(false);
                return Arr(res["Directory"]).Select(d => FolderItem(UriOf($"sgenre:{arg}/{Str(d["key"])}"), Str(d["title"]) ?? "", kind: SourceItemKind.Genre)).ToList();
            }
            case "sgenre":
            {
                var slash = arg.IndexOf('/');
                return await ItemsAsync(await ApiAsync($"/library/sections/{arg[..slash]}/all?type=9&genre={arg[(slash + 1)..]}", ct).ConfigureAwait(false), ct).ConfigureAwait(false);
            }
            case "artist":
            case "album":
                return await ItemsAsync(await ApiAsync($"/library/metadata/{arg}/children", ct).ConfigureAwait(false), ct).ConfigureAwait(false);
            case "playlists": return await ItemsAsync(await ApiAsync("/playlists?playlistType=audio", ct).ConfigureAwait(false), ct).ConfigureAwait(false);
            case "playlist": return await ItemsAsync(await ApiAsync($"/playlists/{arg}/items", ct).ConfigureAwait(false), ct).ConfigureAwait(false);
            default: throw new SourceException($"Unknown Plex node {id}");
        }
    }

    public override async Task<IReadOnlyList<SourceItem>> SearchAsync(string query, CancellationToken ct = default)
    {
        var res = await ApiAsync($"/hubs/search?query={Uri.EscapeDataString(query)}&limit=50", ct).ConfigureAwait(false);
        var items = new List<SourceItem>();
        foreach (var hub in Arr(res["Hub"]).Where(h => Str(h["type"]) is "artist" or "album" or "track"))
            items.AddRange(await ItemsAsync(hub, ct).ConfigureAwait(false));
        return items;
    }

    private async Task<JsonNode?> MetadataAsync(string ratingKey, CancellationToken ct)
    {
        var res = await ApiAsync($"/library/metadata/{ratingKey}", ct).ConfigureAwait(false);
        return Arr(res["Metadata"]).FirstOrDefault();
    }

    public override async Task<Track?> GetTrackAsync(string uri, CancellationToken ct = default)
    {
        try
        {
            var m = await MetadataAsync(IdOf(uri), ct).ConfigureAwait(false);
            return m is null ? null : await ToTrackAsync(m, ct).ConfigureAwait(false);
        }
        catch (SourceException ex) when (ex is not SourceAuthenticationException) { return null; }
    }

    public override async Task<MediaLocation> ResolveAsync(string uri, CancellationToken ct = default)
    {
        var m = await MetadataAsync(IdOf(uri), ct).ConfigureAwait(false) ?? throw new SourceException("Track not found on Plex.");
        var part = Arr(Arr(m["Media"]).FirstOrDefault()?["Part"]).FirstOrDefault() ?? throw new SourceException("Track has no media part.");
        var token = await TokenAsync(ct).ConfigureAwait(false);
        var url = $"{ServerUrl}{Str(part["key"])}?X-Plex-Token={Uri.EscapeDataString(token)}";
        var track = await ToTrackAsync(m, ct).ConfigureAwait(false);
        return MediaLocation.ForUrl(url, null, Long(part["size"]) is > 0 and var s ? s : -1, track.FileName);
    }

    /// <summary>Marks the track as played (scrobble) on the server.</summary>
    public async Task ScrobbleAsync(string uri, CancellationToken ct = default) =>
        await ApiAsync($"/:/scrobble?identifier=com.plexapp.plugins.library&key={IdOf(uri)}", ct).ConfigureAwait(false);
}
