using System.Globalization;
using System.Net;
using System.Text.Json;
using Microsoft.Extensions.Logging;
using MuurMusic.Core.Data;
using MuurMusic.Core.Models;
using MuurMusic.Core.Sources;
using MuurMusic.Core.Tags;

namespace MuurMusic.Core.Metadata;

/// <summary>A MusicBrainz recording-on-release match for a track.</summary>
public sealed record MusicBrainzMatch(
    string RecordingId, string Title, string Artist, string? ArtistId, long? LengthMs,
    string? ReleaseId, string? ReleaseTitle, string? ReleaseArtist, string? ReleaseGroupId, int? Year,
    int? TrackNumber, int? TrackCount, int? DiscNumber, int? DiscCount, int Score, string? Country, string? Status);

/// <summary>Release with its tracklist (for album-level tagging).</summary>
public sealed record MusicBrainzRelease(string Id, string Title, string Artist, int? Year, string? ReleaseGroupId, string? Country, IReadOnlyList<MusicBrainzReleaseTrack> Tracks, IReadOnlyList<string> Genres);
public sealed record MusicBrainzReleaseTrack(string RecordingId, string Title, string Artist, int DiscNumber, int TrackNumber, int TrackCount, int DiscCount, long? LengthMs);

public sealed record AutoTagOptions
{
    /// <summary>Write the new tags into the audio file (local files only).</summary>
    public bool WriteTags { get; init; } = true;
    /// <summary>Download front cover from the Cover Art Archive.</summary>
    public bool FetchCoverArt { get; init; } = true;
    /// <summary>Embed the downloaded cover into the file.</summary>
    public bool EmbedCoverArt { get; init; }
    /// <summary>Keep existing non-empty fields instead of overwriting them.</summary>
    public bool OnlyFillEmpty { get; init; }
}

/// <summary>MusicBrainz search/lookup (rate-limited to 1 request/s with the MuurMusic User-Agent) and Cover Art Archive.</summary>
public interface IMusicBrainzService
{
    Task<IReadOnlyList<MusicBrainzMatch>> SearchRecordingsAsync(Track track, CancellationToken ct = default);
    Task<IReadOnlyList<MusicBrainzMatch>> SearchRecordingsAsync(string title, string? artist, string? album, long? durationMs = null, CancellationToken ct = default);
    Task<IReadOnlyList<MusicBrainzRelease>> SearchReleasesAsync(string album, string? artist, CancellationToken ct = default);
    Task<MusicBrainzRelease?> GetReleaseAsync(string releaseId, CancellationToken ct = default);
    /// <summary>Front cover bytes (500 px) for a release, falling back to its release group; null if none.</summary>
    Task<byte[]?> GetCoverArtAsync(string releaseId, string? releaseGroupId = null, int size = 500, CancellationToken ct = default);
    /// <summary>Best automatic match (score ≥ 90 and duration within 5 s), or null.</summary>
    Task<MusicBrainzMatch?> FindBestMatchAsync(Track track, CancellationToken ct = default);
    /// <summary>Applies a match to a track: updates the library, optionally writes tags and fetches artwork. Returns the updated track.</summary>
    Task<Track> ApplyAsync(Track track, MusicBrainzMatch match, AutoTagOptions? options = null, CancellationToken ct = default);
    /// <summary>Tags all tracks of an album against a release, matching by disc/track number then title.</summary>
    Task<IReadOnlyList<Track>> ApplyReleaseAsync(IReadOnlyList<Track> tracks, MusicBrainzRelease release, AutoTagOptions? options = null, CancellationToken ct = default);
}

public sealed class MusicBrainzService(
    IHttpClientFactory httpFactory,
    ITrackRepository repository,
    ITagService tags,
    IArtworkCache artwork,
    ILogger<MusicBrainzService> logger) : IMusicBrainzService
{
    private const string Api = "https://musicbrainz.org/ws/2/";
    private static readonly SemaphoreSlim Gate = new(1, 1);
    private static DateTimeOffset _last = DateTimeOffset.MinValue;

    private async Task<JsonDocument?> GetAsync(string url, CancellationToken ct)
    {
        for (var attempt = 0; attempt < 3; attempt++)
        {
            await Gate.WaitAsync(ct).ConfigureAwait(false);
            try
            {
                var wait = _last.AddSeconds(1.05) - DateTimeOffset.UtcNow;
                if (wait > TimeSpan.Zero) await Task.Delay(wait, ct).ConfigureAwait(false);
                _last = DateTimeOffset.UtcNow;
                var http = httpFactory.CreateClient(HttpClientNames.Default);
                using var req = new HttpRequestMessage(HttpMethod.Get, url);
                req.Headers.Accept.ParseAdd("application/json");
                using var resp = await http.SendAsync(req, ct).ConfigureAwait(false);
                if (resp.StatusCode == HttpStatusCode.NotFound) return null;
                if (resp.StatusCode == HttpStatusCode.ServiceUnavailable || (int)resp.StatusCode == 429)
                {
                    _last = DateTimeOffset.UtcNow.AddSeconds(2);
                    continue;
                }
                if (!resp.IsSuccessStatusCode) throw new SourceException($"MusicBrainz returned HTTP {(int)resp.StatusCode}.");
                return JsonDocument.Parse(await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false));
            }
            catch (HttpRequestException ex) { throw new SourceException($"MusicBrainz is not reachable: {ex.Message}", ex); }
            finally { Gate.Release(); }
        }
        throw new SourceException("MusicBrainz is busy; try again later.");
    }

    private static string Lucene(string s) =>
        "\"" + new string(s.Where(c => !char.IsControl(c)).ToArray()).Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";

    public Task<IReadOnlyList<MusicBrainzMatch>> SearchRecordingsAsync(Track track, CancellationToken ct = default) =>
        SearchRecordingsAsync(track.Title ?? track.DisplayTitle, track.Artist ?? track.AlbumArtist, track.Album, track.DurationMs > 0 ? track.DurationMs : null, ct);

    public async Task<IReadOnlyList<MusicBrainzMatch>> SearchRecordingsAsync(string title, string? artist, string? album, long? durationMs = null, CancellationToken ct = default)
    {
        var q = "recording:" + Lucene(title);
        if (!string.IsNullOrWhiteSpace(artist)) q += " AND artist:" + Lucene(artist);
        if (!string.IsNullOrWhiteSpace(album)) q += " AND release:" + Lucene(album);
        using var doc = await GetAsync($"{Api}recording?query={Uri.EscapeDataString(q)}&fmt=json&limit=15", ct).ConfigureAwait(false);
        var list = doc is null ? new List<MusicBrainzMatch>() : ParseRecordings(doc.RootElement);
        if (list.Count == 0 && !string.IsNullOrWhiteSpace(album))
            return await SearchRecordingsAsync(title, artist, null, durationMs, ct).ConfigureAwait(false);
        if (durationMs is > 0)
            list = list.OrderByDescending(m => m.Score - (m.LengthMs is { } l ? Math.Min(30, Math.Abs(l - durationMs.Value) / 1000) : 10)).ToList();
        return list;
    }

    internal static List<MusicBrainzMatch> ParseRecordings(JsonElement root)
    {
        var list = new List<MusicBrainzMatch>();
        if (!root.TryGetProperty("recordings", out var recs)) return list;
        foreach (var r in recs.EnumerateArray())
        {
            var id = r.GetProperty("id").GetString()!;
            var title = r.TryGetProperty("title", out var t) ? t.GetString() ?? "" : "";
            var score = r.TryGetProperty("score", out var s) && s.TryGetInt32(out var sc) ? sc : 0;
            long? length = r.TryGetProperty("length", out var l) && l.ValueKind == JsonValueKind.Number ? l.GetInt64() : null;
            var (artist, artistId) = Credit(r);
            if (!r.TryGetProperty("releases", out var releases) || releases.GetArrayLength() == 0)
            {
                list.Add(new MusicBrainzMatch(id, title, artist, artistId, length, null, null, null, null, null, null, null, null, null, score, null, null));
                continue;
            }
            foreach (var rel in releases.EnumerateArray().Take(8))
            {
                int? trackNo = null, trackCount = null, discNo = null;
                if (rel.TryGetProperty("media", out var media) && media.GetArrayLength() > 0)
                {
                    var m = media[0];
                    discNo = m.TryGetProperty("position", out var p) && p.TryGetInt32(out var pi) ? pi : null;
                    trackCount = m.TryGetProperty("track-count", out var tc) && tc.TryGetInt32(out var tci) ? tci : null;
                    if (m.TryGetProperty("track", out var tr) && tr.GetArrayLength() > 0 && tr[0].TryGetProperty("number", out var num) && int.TryParse(num.GetString(), out var n)) trackNo = n;
                }
                var (relArtist, _) = rel.TryGetProperty("artist-credit", out _) ? Credit(rel) : (artist, artistId);
                list.Add(new MusicBrainzMatch(id, title, artist, artistId, length,
                    rel.GetProperty("id").GetString(), rel.TryGetProperty("title", out var rt) ? rt.GetString() : null, relArtist,
                    rel.TryGetProperty("release-group", out var rg) && rg.TryGetProperty("id", out var rgi) ? rgi.GetString() : null,
                    Year(rel), trackNo, trackCount, discNo, null,
                    score, rel.TryGetProperty("country", out var co) ? co.GetString() : null, rel.TryGetProperty("status", out var st) ? st.GetString() : null));
            }
        }
        return list;
    }

    private static (string Name, string? Id) Credit(JsonElement e)
    {
        if (!e.TryGetProperty("artist-credit", out var ac) || ac.ValueKind != JsonValueKind.Array) return ("", null);
        var name = string.Concat(ac.EnumerateArray().Select(c =>
            (c.TryGetProperty("name", out var n) ? n.GetString() : c.TryGetProperty("artist", out var a) && a.TryGetProperty("name", out var an) ? an.GetString() : "") +
            (c.TryGetProperty("joinphrase", out var j) ? j.GetString() : "")));
        var id = ac.GetArrayLength() > 0 && ac[0].TryGetProperty("artist", out var art) && art.TryGetProperty("id", out var aid) ? aid.GetString() : null;
        return (name, id);
    }

    private static int? Year(JsonElement e) =>
        e.TryGetProperty("date", out var d) && d.GetString() is { Length: >= 4 } ds && int.TryParse(ds[..4], out var y) ? y : null;

    public async Task<IReadOnlyList<MusicBrainzRelease>> SearchReleasesAsync(string album, string? artist, CancellationToken ct = default)
    {
        var q = "release:" + Lucene(album) + (string.IsNullOrWhiteSpace(artist) ? "" : " AND artist:" + Lucene(artist));
        using var doc = await GetAsync($"{Api}release?query={Uri.EscapeDataString(q)}&fmt=json&limit=15", ct).ConfigureAwait(false);
        if (doc is null || !doc.RootElement.TryGetProperty("releases", out var rels)) return Array.Empty<MusicBrainzRelease>();
        return rels.EnumerateArray().Select(r => new MusicBrainzRelease(
            r.GetProperty("id").GetString()!, r.TryGetProperty("title", out var t) ? t.GetString() ?? "" : "", Credit(r).Name, Year(r),
            r.TryGetProperty("release-group", out var rg) && rg.TryGetProperty("id", out var rgi) ? rgi.GetString() : null,
            r.TryGetProperty("country", out var c) ? c.GetString() : null, Array.Empty<MusicBrainzReleaseTrack>(), Array.Empty<string>())).ToList();
    }

    public async Task<MusicBrainzRelease?> GetReleaseAsync(string releaseId, CancellationToken ct = default)
    {
        using var doc = await GetAsync($"{Api}release/{Uri.EscapeDataString(releaseId)}?inc=recordings+artist-credits+genres+release-groups&fmt=json", ct).ConfigureAwait(false);
        if (doc is null) return null;
        var r = doc.RootElement;
        var tracks = new List<MusicBrainzReleaseTrack>();
        var media = r.TryGetProperty("media", out var m) ? m.EnumerateArray().ToList() : new List<JsonElement>();
        foreach (var medium in media)
        {
            var disc = medium.TryGetProperty("position", out var p) && p.TryGetInt32(out var pi) ? pi : 1;
            var count = medium.TryGetProperty("track-count", out var tc) && tc.TryGetInt32(out var tci) ? tci : 0;
            if (!medium.TryGetProperty("tracks", out var trs)) continue;
            foreach (var tr in trs.EnumerateArray())
            {
                var rec = tr.GetProperty("recording");
                var pos = tr.TryGetProperty("position", out var tp) && tp.TryGetInt32(out var tpi) ? tpi : 0;
                tracks.Add(new MusicBrainzReleaseTrack(rec.GetProperty("id").GetString()!,
                    tr.TryGetProperty("title", out var tt) ? tt.GetString() ?? "" : rec.GetProperty("title").GetString() ?? "",
                    tr.TryGetProperty("artist-credit", out _) ? Credit(tr).Name : Credit(rec).Name, disc, pos, count, media.Count,
                    tr.TryGetProperty("length", out var len) && len.ValueKind == JsonValueKind.Number ? len.GetInt64() : null));
            }
        }
        var genres = r.TryGetProperty("genres", out var g) ? g.EnumerateArray().OrderByDescending(x => x.TryGetProperty("count", out var c) ? c.GetInt32() : 0)
            .Select(x => x.GetProperty("name").GetString()!).Take(3).ToList() : new List<string>();
        if (genres.Count == 0 && r.TryGetProperty("release-group", out var rgg) && rgg.TryGetProperty("genres", out var rgGenres))
            genres = rgGenres.EnumerateArray().Select(x => x.GetProperty("name").GetString()!).Take(3).ToList();
        return new MusicBrainzRelease(r.GetProperty("id").GetString()!, r.TryGetProperty("title", out var t) ? t.GetString() ?? "" : "", Credit(r).Name, Year(r),
            r.TryGetProperty("release-group", out var rg) && rg.TryGetProperty("id", out var rgi) ? rgi.GetString() : null,
            r.TryGetProperty("country", out var co) ? co.GetString() : null, tracks, genres);
    }

    public async Task<byte[]?> GetCoverArtAsync(string releaseId, string? releaseGroupId = null, int size = 500, CancellationToken ct = default)
    {
        var http = httpFactory.CreateClient(HttpClientNames.Default);
        var sizeSuffix = size switch { <= 250 => "-250", <= 500 => "-500", <= 1200 => "-1200", _ => "" };
        foreach (var url in new[] { $"https://coverartarchive.org/release/{releaseId}/front{sizeSuffix}", releaseGroupId is null ? null : $"https://coverartarchive.org/release-group/{releaseGroupId}/front{sizeSuffix}" })
        {
            if (url is null) continue;
            try
            {
                using var resp = await http.GetAsync(url, ct).ConfigureAwait(false);
                if (resp.IsSuccessStatusCode) return await resp.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false);
            }
            catch (HttpRequestException ex) { logger.LogDebug(ex, "Cover Art Archive request failed"); }
        }
        return null;
    }

    public async Task<MusicBrainzMatch?> FindBestMatchAsync(Track track, CancellationToken ct = default)
    {
        var matches = await SearchRecordingsAsync(track, ct).ConfigureAwait(false);
        return matches.FirstOrDefault(m => m.Score >= 90 && (track.DurationMs <= 0 || m.LengthMs is null || Math.Abs(m.LengthMs.Value - track.DurationMs) <= 5000)
            && (m.Status is null or "Official"));
    }

    public async Task<Track> ApplyAsync(Track track, MusicBrainzMatch match, AutoTagOptions? options = null, CancellationToken ct = default)
    {
        options ??= new AutoTagOptions();
        var t = track.Clone();
        string? Pick(string? current, string? value) => options.OnlyFillEmpty && !string.IsNullOrWhiteSpace(current) ? current : string.IsNullOrWhiteSpace(value) ? current : value;
        int? PickInt(int? current, int? value) => options.OnlyFillEmpty && current is > 0 ? current : value ?? current;
        t.Title = Pick(t.Title, match.Title);
        t.Artist = Pick(t.Artist, match.Artist);
        t.Album = Pick(t.Album, match.ReleaseTitle);
        t.AlbumArtist = Pick(t.AlbumArtist, match.ReleaseArtist);
        t.Year = PickInt(t.Year, match.Year);
        if (!t.IsCueTrack)
        {
            t.TrackNumber = PickInt(t.TrackNumber, match.TrackNumber);
            t.TrackTotal = PickInt(t.TrackTotal, match.TrackCount);
            t.DiscNumber = PickInt(t.DiscNumber, match.DiscNumber);
        }
        t.MusicBrainzRecordingId = match.RecordingId;
        t.MusicBrainzReleaseId = match.ReleaseId ?? t.MusicBrainzReleaseId;
        await PersistAsync(t, match.ReleaseId, match.ReleaseGroupId, options, null, ct).ConfigureAwait(false);
        return t;
    }

    public async Task<IReadOnlyList<Track>> ApplyReleaseAsync(IReadOnlyList<Track> tracks, MusicBrainzRelease release, AutoTagOptions? options = null, CancellationToken ct = default)
    {
        options ??= new AutoTagOptions();
        var result = new List<Track>();
        var remaining = release.Tracks.ToList();
        byte[]? cover = null;
        var coverFetched = false;
        foreach (var track in tracks)
        {
            var disc = track.DiscNumber ?? 1;
            var rt = remaining.FirstOrDefault(r => track.TrackNumber is { } n && r.TrackNumber == n && r.DiscNumber == disc)
                     ?? remaining.OrderByDescending(r => Similarity(r.Title, track.Title ?? track.DisplayTitle)).FirstOrDefault(r => Similarity(r.Title, track.Title ?? track.DisplayTitle) > 0.6);
            if (rt is null) { result.Add(track); continue; }
            remaining.Remove(rt);
            var t = track.Clone();
            string? Pick(string? current, string? value) => options.OnlyFillEmpty && !string.IsNullOrWhiteSpace(current) ? current : string.IsNullOrWhiteSpace(value) ? current : value;
            t.Title = Pick(t.Title, rt.Title);
            t.Artist = Pick(t.Artist, rt.Artist);
            t.Album = Pick(t.Album, release.Title);
            t.AlbumArtist = Pick(t.AlbumArtist, release.Artist);
            t.Year = options.OnlyFillEmpty && t.Year is > 0 ? t.Year : release.Year ?? t.Year;
            if (release.Genres.Count > 0) t.Genre = Pick(t.Genre, string.Join("; ", release.Genres));
            t.TrackNumber = rt.TrackNumber;
            t.TrackTotal = rt.TrackCount;
            t.DiscNumber = rt.DiscNumber;
            t.DiscTotal = rt.DiscCount;
            t.MusicBrainzRecordingId = rt.RecordingId;
            t.MusicBrainzReleaseId = release.Id;
            if (options.FetchCoverArt && !coverFetched)
            {
                cover = await GetCoverArtAsync(release.Id, release.ReleaseGroupId, 1200, ct).ConfigureAwait(false);
                coverFetched = true;
            }
            await PersistAsync(t, null, null, options with { FetchCoverArt = false }, cover, ct).ConfigureAwait(false);
            result.Add(t);
        }
        return result;
    }

    private async Task PersistAsync(Track t, string? releaseId, string? releaseGroupId, AutoTagOptions options, byte[]? cover, CancellationToken ct)
    {
        if (cover is null && options.FetchCoverArt && releaseId is not null && (string.IsNullOrEmpty(t.ArtworkHash) || !options.OnlyFillEmpty))
            cover = await GetCoverArtAsync(releaseId, releaseGroupId, 1200, ct).ConfigureAwait(false);
        if (cover is not null) t.ArtworkHash = await artwork.StoreAsync(cover, ct).ConfigureAwait(false);
        if (t.Id > 0)
        {
            await repository.UpdateTagsAsync(new[] { t }, ct).ConfigureAwait(false);
            if (cover is not null) await repository.SetArtworkAsync(new[] { t.Id }, t.ArtworkHash, ct).ConfigureAwait(false);
        }
        if (options.WriteTags && !t.IsCueTrack && !string.IsNullOrEmpty(t.FilePath) && tags.CanHandle(t.FilePath) && File.Exists(t.FilePath))
        {
            await tags.WriteAsync(t.FilePath, new TagEdit
            {
                Title = t.Title, Artist = t.Artist, Album = t.Album, AlbumArtist = t.AlbumArtist, Genre = t.Genre, Year = t.Year,
                TrackNumber = t.TrackNumber, TrackTotal = t.TrackTotal, DiscNumber = t.DiscNumber, DiscTotal = t.DiscTotal,
                MusicBrainzRecordingId = t.MusicBrainzRecordingId, MusicBrainzReleaseId = t.MusicBrainzReleaseId,
                Artwork = options.EmbedCoverArt ? cover : null
            }, ct).ConfigureAwait(false);
        }
    }

    /// <summary>Normalized similarity (0..1) based on Levenshtein distance of lower-cased alphanumerics.</summary>
    internal static double Similarity(string a, string b)
    {
        static string Norm(string s) => new(s.ToLower(CultureInfo.InvariantCulture).Where(char.IsLetterOrDigit).ToArray());
        var x = Norm(a);
        var y = Norm(b);
        if (x.Length == 0 && y.Length == 0) return 1;
        var d = new int[y.Length + 1];
        for (var j = 0; j <= y.Length; j++) d[j] = j;
        for (var i = 1; i <= x.Length; i++)
        {
            var prev = d[0];
            d[0] = i;
            for (var j = 1; j <= y.Length; j++)
            {
                var tmp = d[j];
                d[j] = Math.Min(Math.Min(d[j] + 1, d[j - 1] + 1), prev + (x[i - 1] == y[j - 1] ? 0 : 1));
                prev = tmp;
            }
        }
        return 1.0 - (double)d[y.Length] / Math.Max(x.Length, y.Length);
    }
}
