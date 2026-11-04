using System.Globalization;
using System.Text;
using MuurMusic.Core.Models;

namespace MuurMusic.Core.Playlists;

/// <summary>PLS (Winamp/Shoutcast) playlist reader and writer: [playlist] FileN= TitleN= LengthN= NumberOfEntries= Version=2.</summary>
public static class PlsFormat
{
    public static IReadOnlyList<M3uEntry> Parse(string text)
    {
        var files = new SortedDictionary<int, string>();
        var titles = new Dictionary<int, string>();
        var lengths = new Dictionary<int, double>();
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Trim().TrimStart('\uFEFF');
            if (line.Length == 0 || line.StartsWith(';') || line.StartsWith('[')) continue;
            var eq = line.IndexOf('=');
            if (eq <= 0) continue;
            var key = line[..eq].Trim();
            var value = line[(eq + 1)..].Trim();
            if (TryIndex(key, "File", out var n)) files[n] = value;
            else if (TryIndex(key, "Title", out n)) titles[n] = value;
            else if (TryIndex(key, "Length", out n) && double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var len) && len >= 0) lengths[n] = len;
        }
        var result = new List<M3uEntry>();
        foreach (var (n, file) in files)
        {
            string? artist = null, title = titles.GetValueOrDefault(n);
            if (title is not null)
            {
                var sep = title.IndexOf(" - ", StringComparison.Ordinal);
                if (sep > 0) { artist = title[..sep].Trim(); title = title[(sep + 3)..].Trim(); }
            }
            result.Add(new M3uEntry(file, lengths.TryGetValue(n, out var l) ? l : null, artist, title));
        }
        return result;
    }

    private static bool TryIndex(string key, string prefix, out int index)
    {
        index = 0;
        return key.Length > prefix.Length && key.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)
            && int.TryParse(key.AsSpan(prefix.Length), NumberStyles.None, CultureInfo.InvariantCulture, out index);
    }

    public static IReadOnlyList<M3uEntry> Read(string path) => Parse(M3uFormat.ReadText(path));

    public static string Write(IEnumerable<Track> tracks, string playlistPath)
    {
        var sb = new StringBuilder("[playlist]\r\n");
        var n = 0;
        foreach (var t in tracks)
        {
            n++;
            sb.Append("File").Append(n).Append('=').Append(M3uFormat.LocationFor(t, playlistPath)).Append("\r\n");
            sb.Append("Title").Append(n).Append('=').Append(t.DisplayArtist).Append(" - ").Append(t.DisplayTitle).Append("\r\n");
            sb.Append("Length").Append(n).Append('=').Append(t.DurationMs > 0 ? Math.Round(t.DurationMs / 1000.0).ToString(CultureInfo.InvariantCulture) : "-1").Append("\r\n");
        }
        sb.Append("NumberOfEntries=").Append(n).Append("\r\nVersion=2\r\n");
        return sb.ToString();
    }
}
