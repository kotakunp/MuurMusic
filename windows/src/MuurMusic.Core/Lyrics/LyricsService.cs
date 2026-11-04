using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Logging;
using MuurMusic.Core.Data;
using MuurMusic.Core.Infrastructure;
using MuurMusic.Core.Models;
using MuurMusic.Core.Settings;
using MuurMusic.Core.Sources;
using MuurMusic.Core.Tags;

namespace MuurMusic.Core.Lyrics;

public enum LyricsOrigin { None, UserSaved, Sidecar, Embedded, Online }

public sealed record LyricsResult(LyricsDocument Document, LyricsOrigin Origin, string? RawText)
{
    public static readonly LyricsResult None = new(new LyricsDocument(), LyricsOrigin.None, null);
    public bool Found => Origin != LyricsOrigin.None && !Document.IsEmpty;
}

/// <summary>Finds, caches, edits and fetches lyrics (user cache, sidecar .lrc/.txt, embedded tags, LRCLIB).</summary>
public interface ILyricsService
{
    /// <summary>Gets lyrics, preferring synced versions. Online lookup honors settings and offline mode unless <paramref name="allowOnline"/> is false.</summary>
    Task<LyricsResult> GetAsync(Track track, bool allowOnline = true, CancellationToken ct = default);
    /// <summary>Queries LRCLIB directly (ignores caches), returning null if nothing matched.</summary>
    Task<LyricsResult?> FetchOnlineAsync(Track track, CancellationToken ct = default);
    /// <summary>Saves edited lyrics to the user cache, and optionally embeds them into the file's tags.</summary>
    Task SaveAsync(Track track, string lrcOrText, bool embedInFile = false, CancellationToken ct = default);
    /// <summary>Removes user-saved/online-cached lyrics for the track.</summary>
    Task DeleteCachedAsync(Track track, CancellationToken ct = default);
    /// <summary>Per-track display offset in ms (positive = lyrics later).</summary>
    Task<long> GetOffsetAsync(Track track, CancellationToken ct = default);
    Task SetOffsetAsync(Track track, long offsetMs, CancellationToken ct = default);
}

public sealed class LyricsService(
    AppPaths paths,
    ITagService tags,
    ITrackRepository tracks,
    IKeyValueStore kv,
    ISettingsService settings,
    IHttpClientFactory httpFactory,
    ILogger<LyricsService> logger) : ILyricsService
{
    private const string LrcLib = "https://lrclib.net/api/";

    private string CachePath(Track t, string ext) =>
        Path.Combine(paths.LyricsDirectory, Convert.ToHexStringLower(SHA1.HashData(Encoding.UTF8.GetBytes(t.Key))) + ext);

    private static IEnumerable<string> SidecarCandidates(Track t)
    {
        if (string.IsNullOrEmpty(t.FilePath)) yield break;
        var dir = Path.GetDirectoryName(t.FilePath)!;
        var stem = Path.GetFileNameWithoutExtension(t.FilePath);
        if (t.IsCueTrack && t.TrackNumber is { } n)
        {
            yield return Path.Combine(dir, $"{n:00} - {t.Title}.lrc");
            yield return Path.Combine(dir, $"{stem} - {n:00}.lrc");
        }
        yield return Path.Combine(dir, stem + ".lrc");
        yield return Path.Combine(dir, stem + ".LRC");
        yield return Path.Combine(dir, stem + ".txt");
    }

    public async Task<LyricsResult> GetAsync(Track track, bool allowOnline = true, CancellationToken ct = default)
    {
        LyricsResult? unsynced = null;
        foreach (var ext in new[] { ".lrc", ".txt" })
        {
            var cached = CachePath(track, ext);
            if (!File.Exists(cached)) continue;
            var text = await File.ReadAllTextAsync(cached, ct).ConfigureAwait(false);
            var r = new LyricsResult(LrcParser.Parse(text), LyricsOrigin.UserSaved, text);
            if (r.Document.IsSynced) return r;
            unsynced ??= r;
        }
        if (!track.IsCueTrack || track.TrackNumber is not null)
        {
            foreach (var path in SidecarCandidates(track))
            {
                if (!File.Exists(path)) continue;
                var text = Playlists.M3uFormat.ReadText(path);
                var r = new LyricsResult(LrcParser.Parse(text), LyricsOrigin.Sidecar, text);
                if (r.Document.IsEmpty) continue;
                if (r.Document.IsSynced) return r;
                unsynced ??= r;
            }
        }
        if (!track.IsCueTrack && !string.IsNullOrEmpty(track.FilePath) && tags.CanHandle(track.FilePath))
        {
            var embedded = await Task.Run(() => tags.ReadLyrics(track.FilePath!), ct).ConfigureAwait(false);
            if (!string.IsNullOrWhiteSpace(embedded))
            {
                var r = new LyricsResult(LrcParser.Parse(embedded), LyricsOrigin.Embedded, embedded);
                if (r.Document.IsSynced) return r;
                unsynced ??= r;
            }
        }
        var s = settings.Current;
        if (allowOnline && s.FetchLyricsOnline && !s.OfflineMode && !string.IsNullOrWhiteSpace(track.Title))
        {
            var online = await FetchOnlineAsync(track, ct).ConfigureAwait(false);
            if (online is not null && (online.Document.IsSynced || unsynced is null))
            {
                await CacheOnlineAsync(track, online, ct).ConfigureAwait(false);
                return online;
            }
        }
        return unsynced ?? LyricsResult.None;
    }

    private async Task CacheOnlineAsync(Track track, LyricsResult r, CancellationToken ct)
    {
        try
        {
            await File.WriteAllTextAsync(CachePath(track, r.Document.IsSynced ? ".lrc" : ".txt"), r.RawText ?? r.Document.ToLrc(), ct).ConfigureAwait(false);
            if (track.Id > 0 && !track.HasLyrics) await tracks.SetHasLyricsAsync(track.Id, true, ct).ConfigureAwait(false);
        }
        catch (IOException ex) { logger.LogDebug(ex, "Could not cache lyrics"); }
    }

    public async Task<LyricsResult?> FetchOnlineAsync(Track track, CancellationToken ct = default)
    {
        var http = httpFactory.CreateClient(HttpClientNames.Default);
        var title = track.Title ?? track.DisplayTitle;
        var artist = track.Artist ?? track.AlbumArtist ?? "";
        try
        {
            var q = $"track_name={Uri.EscapeDataString(title)}&artist_name={Uri.EscapeDataString(artist)}";
            if (!string.IsNullOrEmpty(track.Album)) q += "&album_name=" + Uri.EscapeDataString(track.Album);
            if (track.DurationMs > 0) q += "&duration=" + (track.DurationMs / 1000);
            using (var resp = await http.GetAsync(LrcLib + "get?" + q, ct).ConfigureAwait(false))
            {
                if (resp.IsSuccessStatusCode)
                {
                    using var doc = JsonDocument.Parse(await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false));
                    if (FromLrcLib(doc.RootElement) is { } r) return r;
                }
                else if (resp.StatusCode != HttpStatusCode.NotFound)
                    logger.LogDebug("LRCLIB get returned {Status}", (int)resp.StatusCode);
            }
            var sq = $"track_name={Uri.EscapeDataString(title)}" + (artist.Length > 0 ? "&artist_name=" + Uri.EscapeDataString(artist) : "");
            using var search = await http.GetAsync(LrcLib + "search?" + sq, ct).ConfigureAwait(false);
            if (!search.IsSuccessStatusCode) return null;
            using var arr = JsonDocument.Parse(await search.Content.ReadAsStringAsync(ct).ConfigureAwait(false));
            var candidates = arr.RootElement.EnumerateArray()
                .Select(e => (E: e, Dur: e.TryGetProperty("duration", out var d) && d.ValueKind == JsonValueKind.Number ? d.GetDouble() : 0,
                    Synced: e.TryGetProperty("syncedLyrics", out var sl) && sl.ValueKind == JsonValueKind.String))
                .Where(c => track.DurationMs <= 0 || c.Dur <= 0 || Math.Abs(c.Dur - track.DurationMs / 1000.0) <= 3)
                .OrderByDescending(c => c.Synced)
                .ThenBy(c => track.DurationMs > 0 && c.Dur > 0 ? Math.Abs(c.Dur - track.DurationMs / 1000.0) : 0)
                .ToList();
            foreach (var c in candidates)
                if (FromLrcLib(c.E) is { } r) return r;
            return null;
        }
        catch (Exception ex) when (ex is HttpRequestException or JsonException or TaskCanceledException && !ct.IsCancellationRequested)
        {
            logger.LogDebug(ex, "LRCLIB lookup failed for {Title}", title);
            return null;
        }
    }

    private static LyricsResult? FromLrcLib(JsonElement e)
    {
        if (e.TryGetProperty("syncedLyrics", out var synced) && synced.ValueKind == JsonValueKind.String && !string.IsNullOrWhiteSpace(synced.GetString()))
        {
            var text = synced.GetString()!;
            return new LyricsResult(LrcParser.Parse(text), LyricsOrigin.Online, text);
        }
        if (e.TryGetProperty("plainLyrics", out var plain) && plain.ValueKind == JsonValueKind.String && !string.IsNullOrWhiteSpace(plain.GetString()))
        {
            var text = plain.GetString()!;
            return new LyricsResult(LrcParser.Parse(text), LyricsOrigin.Online, text);
        }
        return null;
    }

    public async Task SaveAsync(Track track, string lrcOrText, bool embedInFile = false, CancellationToken ct = default)
    {
        var synced = LrcParser.LooksSynced(lrcOrText);
        var target = CachePath(track, synced ? ".lrc" : ".txt");
        var other = CachePath(track, synced ? ".txt" : ".lrc");
        if (File.Exists(other)) File.Delete(other);
        await File.WriteAllTextAsync(target, lrcOrText, new UTF8Encoding(false), ct).ConfigureAwait(false);
        if (embedInFile && !track.IsCueTrack && !string.IsNullOrEmpty(track.FilePath) && tags.CanHandle(track.FilePath))
            await tags.WriteAsync(track.FilePath, new TagEdit { Lyrics = lrcOrText }, ct).ConfigureAwait(false);
        if (track.Id > 0) await tracks.SetHasLyricsAsync(track.Id, !string.IsNullOrWhiteSpace(lrcOrText), ct).ConfigureAwait(false);
    }

    public Task DeleteCachedAsync(Track track, CancellationToken ct = default)
    {
        foreach (var ext in new[] { ".lrc", ".txt" })
        {
            var p = CachePath(track, ext);
            if (File.Exists(p)) File.Delete(p);
        }
        return Task.CompletedTask;
    }

    public async Task<long> GetOffsetAsync(Track track, CancellationToken ct = default) =>
        long.TryParse(await kv.GetAsync("lyrics.offset:" + track.Key, ct).ConfigureAwait(false), out var v) ? v : 0;

    public Task SetOffsetAsync(Track track, long offsetMs, CancellationToken ct = default) =>
        kv.SetAsync("lyrics.offset:" + track.Key, offsetMs == 0 ? null : offsetMs.ToString(System.Globalization.CultureInfo.InvariantCulture), ct);
}
