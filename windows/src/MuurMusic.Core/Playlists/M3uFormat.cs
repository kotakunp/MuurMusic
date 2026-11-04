using System.Globalization;
using System.Text;
using MuurMusic.Core.Models;
using MuurMusic.Core.Sources;

namespace MuurMusic.Core.Playlists;

/// <summary>One M3U entry. <see cref="Location"/> is the raw path/URI as written in the file.</summary>
public sealed record M3uEntry(string Location, double? DurationSeconds = null, string? Artist = null, string? Title = null);

/// <summary>M3U / M3U8 reader and writer (#EXTM3U, #EXTINF:&lt;seconds&gt;,&lt;artist&gt; - &lt;title&gt;).</summary>
public static class M3uFormat
{
    static M3uFormat() => Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);

    public static IReadOnlyList<M3uEntry> Parse(string text)
    {
        var entries = new List<M3uEntry>();
        double? duration = null;
        string? artist = null, title = null;
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Trim().TrimStart('\uFEFF');
            if (line.Length == 0) continue;
            if (line.StartsWith('#'))
            {
                if (line.StartsWith("#EXTINF:", StringComparison.OrdinalIgnoreCase))
                {
                    var body = line[8..];
                    var comma = FindInfoComma(body);
                    var durText = comma >= 0 ? body[..comma] : body;
                    // Attributes like tvg-id="x" may follow the duration; the duration is the first token.
                    var firstToken = durText.Split(' ', 2)[0];
                    duration = double.TryParse(firstToken, NumberStyles.Float, CultureInfo.InvariantCulture, out var d) && d >= 0 ? d : null;
                    var info = comma >= 0 ? body[(comma + 1)..].Trim() : "";
                    var sep = info.IndexOf(" - ", StringComparison.Ordinal);
                    if (sep > 0) { artist = info[..sep].Trim(); title = info[(sep + 3)..].Trim(); }
                    else { artist = null; title = info.Length > 0 ? info : null; }
                }
                continue;
            }
            entries.Add(new M3uEntry(line, duration, artist, title));
            duration = null;
            artist = title = null;
        }
        return entries;
    }

    private static int FindInfoComma(string s)
    {
        var inQuotes = false;
        for (var i = 0; i < s.Length; i++)
        {
            if (s[i] == '"') inQuotes = !inQuotes;
            else if (s[i] == ',' && !inQuotes) return i;
        }
        return -1;
    }

    public static IReadOnlyList<M3uEntry> Read(string path) => Parse(ReadText(path));

    /// <summary>Reads a playlist/cue text file: UTF-8 (with or without BOM) when valid, otherwise the ANSI code page.</summary>
    public static string ReadText(string path)
    {
        var bytes = File.ReadAllBytes(path);
        return DecodeText(bytes, path.EndsWith(".m3u8", StringComparison.OrdinalIgnoreCase));
    }

    internal static string DecodeText(byte[] bytes, bool forceUtf8)
    {
        if (bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) return Encoding.UTF8.GetString(bytes, 3, bytes.Length - 3);
        if (bytes.Length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) return Encoding.Unicode.GetString(bytes, 2, bytes.Length - 2);
        if (bytes.Length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) return Encoding.BigEndianUnicode.GetString(bytes, 2, bytes.Length - 2);
        if (forceUtf8) return Encoding.UTF8.GetString(bytes);
        try
        {
            return new UTF8Encoding(false, throwOnInvalidBytes: true).GetString(bytes);
        }
        catch (DecoderFallbackException)
        {
            return Encoding.GetEncoding(1252).GetString(bytes);
        }
    }

    /// <summary>Resolves an entry location against the playlist folder: returns an absolute local path or a URI.</summary>
    public static string Resolve(string location, string playlistDirectory)
    {
        var loc = location.Trim();
        if (SourceUris.SchemeOf(loc) is { Length: > 1 } scheme)
        {
            if (scheme == SourceUris.File && SourceUris.TryGetLocalPath(loc, out var p)) return p;
            return loc;
        }
        loc = loc.Replace('/', Path.DirectorySeparatorChar);
        if (Path.IsPathFullyQualified(loc)) return Path.GetFullPath(loc);
        if (loc.StartsWith(Path.DirectorySeparatorChar))
            return Path.GetFullPath(Path.Combine(Path.GetPathRoot(playlistDirectory) ?? "", loc.TrimStart(Path.DirectorySeparatorChar)));
        return Path.GetFullPath(Path.Combine(playlistDirectory, loc));
    }

    /// <summary>
    /// Path to write for a track: relative to the playlist (with '/' separators) when it is on the same volume root,
    /// otherwise the absolute path, or the source URI for non-local tracks.
    /// </summary>
    public static string LocationFor(Track track, string playlistPath)
    {
        string? local = track.FilePath;
        if (local is null && SourceUris.TryGetLocalPath(track.SourceUri, out var p)) local = p;
        if (local is null) return track.SourceUri;
        var dir = Path.GetDirectoryName(Path.GetFullPath(playlistPath))!;
        var full = Path.GetFullPath(local);
        if (string.Equals(Path.GetPathRoot(dir), Path.GetPathRoot(full), StringComparison.OrdinalIgnoreCase))
            return Path.GetRelativePath(dir, full).Replace('\\', '/');
        return full;
    }

    public static string Write(IEnumerable<Track> tracks, string playlistPath)
    {
        var sb = new StringBuilder();
        sb.Append("#EXTM3U\n");
        foreach (var t in tracks)
        {
            var seconds = t.DurationMs > 0 ? (long)Math.Round(t.DurationMs / 1000.0) : -1;
            sb.Append("#EXTINF:").Append(seconds.ToString(CultureInfo.InvariantCulture)).Append(',')
              .Append(t.DisplayArtist).Append(" - ").Append(t.DisplayTitle).Append('\n');
            sb.Append(LocationFor(t, playlistPath)).Append('\n');
        }
        return sb.ToString();
    }

    public static async Task WriteFileAsync(IEnumerable<Track> tracks, string playlistPath, CancellationToken ct = default)
    {
        var text = Write(tracks, playlistPath);
        // .m3u8 is UTF-8 by definition; plain .m3u is also written as UTF-8 (without BOM) which modern players accept.
        await File.WriteAllTextAsync(playlistPath, text, new UTF8Encoding(false), ct).ConfigureAwait(false);
    }
}
