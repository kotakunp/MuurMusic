using System.Text;
using Microsoft.Extensions.Logging;
using MuurMusic.Core.Data;
using MuurMusic.Core.Dsp;
using MuurMusic.Core.Models;
using MuurMusic.Core.Sources;
using MuurMusic.Core.Tags;

namespace MuurMusic.Core.Playlists;

public enum PlaylistFileFormat { M3u, M3u8, Pls, Cue, SmartJson }

/// <summary>Result of a playlist import.</summary>
public sealed record PlaylistImportResult(Playlist Playlist, int Imported, IReadOnlyList<string> Missing);

/// <summary>Imports and exports playlists as M3U/M3U8, PLS, CUE and muur-smart JSON (shared with the Apple apps).</summary>
public interface IPlaylistIoService
{
    /// <summary>File dialog filter extensions this service can import.</summary>
    IReadOnlyList<string> ImportExtensions { get; }
    /// <summary>Imports a playlist file into a new playlist (name defaults to the file name). Smart JSON creates a smart playlist.</summary>
    Task<PlaylistImportResult> ImportAsync(string path, string? name = null, CancellationToken ct = default);
    /// <summary>Reads a playlist file into tracks without storing it (e.g. to play a .m3u opened from Explorer).</summary>
    Task<IReadOnlyList<Track>> ReadTracksAsync(string path, CancellationToken ct = default);
    /// <summary>Exports a playlist. For smart playlists <see cref="PlaylistFileFormat.SmartJson"/> writes the rules; other formats write the current matches.</summary>
    Task ExportAsync(long playlistId, string path, PlaylistFileFormat format, CancellationToken ct = default);
    /// <summary>Writes arbitrary tracks (e.g. the queue) as a playlist file.</summary>
    Task ExportTracksAsync(IEnumerable<Track> tracks, string path, PlaylistFileFormat format, string? title = null, CancellationToken ct = default);
    /// <summary>Returns the tracks of a playlist (resolving smart rules).</summary>
    Task<IReadOnlyList<Track>> GetTracksAsync(long playlistId, bool availableOnly = false, CancellationToken ct = default);
    PlaylistFileFormat FormatFromPath(string path);
}

public sealed class PlaylistIoService(IPlaylistRepository playlists, ITrackRepository tracks, ITagService tags, ILogger<PlaylistIoService> log) : IPlaylistIoService
{
    public IReadOnlyList<string> ImportExtensions { get; } = new[] { ".m3u", ".m3u8", ".pls", ".cue", ".json" };

    public PlaylistFileFormat FormatFromPath(string path) => Path.GetExtension(path).ToLowerInvariant() switch
    {
        ".m3u" => PlaylistFileFormat.M3u,
        ".m3u8" => PlaylistFileFormat.M3u8,
        ".pls" => PlaylistFileFormat.Pls,
        ".cue" => PlaylistFileFormat.Cue,
        ".json" => PlaylistFileFormat.SmartJson,
        var ext => throw new NotSupportedException($"Unsupported playlist format '{ext}'.")
    };

    public async Task<PlaylistImportResult> ImportAsync(string path, string? name = null, CancellationToken ct = default)
    {
        var format = FormatFromPath(path);
        if (format == PlaylistFileFormat.SmartJson)
        {
            var def = DspJson.ReadSmartPlaylist(await File.ReadAllTextAsync(path, ct).ConfigureAwait(false));
            var smartName = name ?? (string.IsNullOrWhiteSpace(def.Name) ? Path.GetFileNameWithoutExtension(path) : def.Name);
            def.Name = smartName;
            var smart = await playlists.CreateAsync(smartName, def, ct).ConfigureAwait(false);
            var count = (await tracks.QuerySmartAsync(def, false, ct).ConfigureAwait(false)).Count;
            return new PlaylistImportResult(smart, count, Array.Empty<string>());
        }

        var (list, missing) = await ReadAsync(path, format, ct).ConfigureAwait(false);
        var playlistName = name ?? Path.GetFileNameWithoutExtension(path);
        if (format == PlaylistFileFormat.Cue && name is null)
        {
            try { playlistName = CueSheet.Load(path).Title ?? playlistName; } catch (IOException) { }
        }
        var playlist = await playlists.CreateAsync(playlistName, null, ct).ConfigureAwait(false);
        await playlists.AddTracksAsync(playlist.Id, list, null, ct).ConfigureAwait(false);
        log.LogInformation("Imported playlist {Name}: {Count} entries, {Missing} missing", playlistName, list.Count, missing.Count);
        return new PlaylistImportResult(await playlists.GetAsync(playlist.Id, ct).ConfigureAwait(false) ?? playlist, list.Count, missing);
    }

    public async Task<IReadOnlyList<Track>> ReadTracksAsync(string path, CancellationToken ct = default)
    {
        var format = FormatFromPath(path);
        if (format == PlaylistFileFormat.SmartJson)
            return await tracks.QuerySmartAsync(DspJson.ReadSmartPlaylist(await File.ReadAllTextAsync(path, ct).ConfigureAwait(false)), true, ct).ConfigureAwait(false);
        return (await ReadAsync(path, format, ct).ConfigureAwait(false)).Tracks;
    }

    private async Task<(List<Track> Tracks, List<string> Missing)> ReadAsync(string path, PlaylistFileFormat format, CancellationToken ct)
    {
        var dir = Path.GetDirectoryName(Path.GetFullPath(path))!;
        var result = new List<Track>();
        var missing = new List<string>();
        if (format == PlaylistFileFormat.Cue)
        {
            var cue = CueSheet.Load(path);
            foreach (var v in cue.ToVirtualTracks(n => CueSheet.ResolveAudioFile(dir, n)))
            {
                ct.ThrowIfCancellationRequested();
                var audio = Path.IsPathFullyQualified(v.AudioFile) ? v.AudioFile : Path.Combine(dir, v.AudioFile);
                var uri = SourceUris.FromLocalPath(audio);
                var t = await tracks.GetBySourceUriAsync(uri, v.StartMs, ct).ConfigureAwait(false);
                if (t is null)
                {
                    if (!File.Exists(audio)) { missing.Add(v.AudioFile); continue; }
                    var baseTrack = ReadLocal(audio);
                    t = Library.LibraryScanner.ExpandCue(baseTrack, cue, path, audio).FirstOrDefault(x => x.CueStartMs == v.StartMs);
                    if (t is null) { missing.Add(v.AudioFile); continue; }
                }
                result.Add(t);
            }
            return (result, missing);
        }

        var entries = format == PlaylistFileFormat.Pls ? PlsFormat.Read(path) : M3uFormat.Read(path);
        foreach (var e in entries)
        {
            ct.ThrowIfCancellationRequested();
            var location = M3uFormat.Resolve(e.Location, dir);
            var t = await ResolveEntryAsync(location, e, ct).ConfigureAwait(false);
            if (t is null) missing.Add(e.Location);
            else result.Add(t);
        }
        return (result, missing);
    }

    private async Task<Track?> ResolveEntryAsync(string location, M3uEntry entry, CancellationToken ct)
    {
        var isUri = SourceUris.SchemeOf(location) is { Length: > 1 };
        if (!isUri)
        {
            var byPath = await tracks.GetByFilePathAsync(location, ct).ConfigureAwait(false);
            if (byPath.Count > 0) return byPath.OrderBy(t => t.CueStartMs).First();
            if (!File.Exists(location)) return null;
            return ReadLocal(location);
        }
        var byUri = await tracks.GetBySourceUriAsync(location, 0, ct).ConfigureAwait(false);
        if (byUri is not null) return byUri;
        return new Track
        {
            SourceUri = location,
            FileName = SourceUris.FileNameOf(location),
            Title = entry.Title,
            Artist = entry.Artist,
            DurationMs = entry.DurationSeconds is { } d ? (long)(d * 1000) : 0,
            IsRemote = true,
            Codec = AudioFormats.CodecFromExtension(SourceUris.FileNameOf(location))
        };
    }

    private Track ReadLocal(string path)
    {
        var read = tags.CanHandle(path) ? tags.Read(path) : null;
        if (read is not null) return read.Track;
        var fi = new FileInfo(path);
        return new Track
        {
            SourceUri = SourceUris.FromLocalPath(path), FilePath = fi.FullName, Folder = fi.DirectoryName, FileName = fi.Name,
            Title = Path.GetFileNameWithoutExtension(fi.Name), FileSize = fi.Length, Codec = AudioFormats.CodecFromExtension(path),
            Format = fi.Extension.TrimStart('.').ToLowerInvariant()
        };
    }

    public async Task<IReadOnlyList<Track>> GetTracksAsync(long playlistId, bool availableOnly = false, CancellationToken ct = default)
    {
        var playlist = await playlists.GetAsync(playlistId, ct).ConfigureAwait(false) ?? throw new InvalidOperationException($"Playlist {playlistId} does not exist.");
        if (playlist.IsSmart && playlist.Smart is not null) return await tracks.QuerySmartAsync(playlist.Smart, availableOnly, ct).ConfigureAwait(false);
        var entries = await playlists.GetEntriesAsync(playlistId, ct).ConfigureAwait(false);
        var list = new List<Track>(entries.Count);
        foreach (var e in entries)
        {
            var t = e.Track ?? new Track
            {
                SourceUri = e.SourceUri, CueStartMs = e.CueStartMs, Title = e.Title, Artist = e.Artist, DurationMs = e.DurationMs,
                FileName = SourceUris.FileNameOf(e.SourceUri), IsRemote = SourceUris.SchemeOf(e.SourceUri) != SourceUris.File
            };
            if (t.FilePath is null && SourceUris.TryGetLocalPath(t.SourceUri, out var p)) t.FilePath = p;
            if (availableOnly && t.IsUnavailable) continue;
            list.Add(t);
        }
        return list;
    }

    public async Task ExportAsync(long playlistId, string path, PlaylistFileFormat format, CancellationToken ct = default)
    {
        var playlist = await playlists.GetAsync(playlistId, ct).ConfigureAwait(false) ?? throw new InvalidOperationException($"Playlist {playlistId} does not exist.");
        if (format == PlaylistFileFormat.SmartJson)
        {
            var def = playlist.Smart ?? throw new InvalidOperationException("Only smart playlists can be exported as muur-smart JSON.");
            def.Name = playlist.Name;
            await File.WriteAllTextAsync(path, DspJson.WriteSmartPlaylist(def), new UTF8Encoding(false), ct).ConfigureAwait(false);
            return;
        }
        await ExportTracksAsync(await GetTracksAsync(playlistId, false, ct).ConfigureAwait(false), path, format, playlist.Name, ct).ConfigureAwait(false);
    }

    public async Task ExportTracksAsync(IEnumerable<Track> trackList, string path, PlaylistFileFormat format, string? title = null, CancellationToken ct = default)
    {
        var list = trackList.ToList();
        var text = format switch
        {
            PlaylistFileFormat.M3u or PlaylistFileFormat.M3u8 => M3uFormat.Write(list, path),
            PlaylistFileFormat.Pls => PlsFormat.Write(list, path),
            PlaylistFileFormat.Cue => CueSheet.FromTracks(list, path, title).Write(),
            _ => throw new NotSupportedException("Track lists cannot be exported as smart playlist JSON.")
        };
        var dir = Path.GetDirectoryName(Path.GetFullPath(path));
        if (dir is not null) Directory.CreateDirectory(dir);
        await File.WriteAllTextAsync(path, text, new UTF8Encoding(false), ct).ConfigureAwait(false);
    }
}
