using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace MuurMusic.Core.Lyrics;

/// <summary>A timed word inside an enhanced LRC line (&lt;mm:ss.xx&gt;word).</summary>
public sealed record LyricWord(long TimeMs, string Text);

/// <summary>One lyric line. <see cref="TimeMs"/> is null for unsynchronized lyrics.</summary>
public sealed record LyricLine(long? TimeMs, string Text, IReadOnlyList<LyricWord> Words)
{
    public bool HasWordTiming => Words.Count > 0;
}

/// <summary>Parsed lyrics (LRC or plain text) with metadata tags.</summary>
public sealed class LyricsDocument
{
    public IReadOnlyList<LyricLine> Lines { get; init; } = Array.Empty<LyricLine>();
    public bool IsSynced { get; init; }
    /// <summary>[offset:] tag in ms as written in the file (already applied to line times).</summary>
    public long OffsetMs { get; init; }
    public string? Title { get; init; }
    public string? Artist { get; init; }
    public string? Album { get; init; }
    public string? Author { get; init; }
    public long? LengthMs { get; init; }
    public IReadOnlyDictionary<string, string> Tags { get; init; } = new Dictionary<string, string>();

    public bool IsEmpty => Lines.Count == 0 || Lines.All(l => string.IsNullOrWhiteSpace(l.Text));

    /// <summary>Index of the line active at <paramref name="positionMs"/> (-1 before the first line or when unsynced).</summary>
    public int LineIndexAt(long positionMs, long extraOffsetMs = 0)
    {
        if (!IsSynced || Lines.Count == 0) return -1;
        var t = positionMs + extraOffsetMs;
        int lo = 0, hi = Lines.Count - 1, found = -1;
        while (lo <= hi)
        {
            var mid = (lo + hi) / 2;
            if ((Lines[mid].TimeMs ?? 0) <= t) { found = mid; lo = mid + 1; }
            else hi = mid - 1;
        }
        return found;
    }

    /// <summary>Plain text without timestamps.</summary>
    public string ToPlainText() => string.Join(Environment.NewLine, Lines.Select(l => l.Text));

    /// <summary>Serializes to LRC (synced) or plain text. Times are written with the offset already applied, so no [offset:] tag is emitted.</summary>
    public string ToLrc()
    {
        var sb = new StringBuilder();
        if (Title is not null) sb.Append("[ti:").Append(Title).Append("]\n");
        if (Artist is not null) sb.Append("[ar:").Append(Artist).Append("]\n");
        if (Album is not null) sb.Append("[al:").Append(Album).Append("]\n");
        if (Author is not null) sb.Append("[by:").Append(Author).Append("]\n");
        foreach (var line in Lines)
        {
            if (IsSynced && line.TimeMs is { } t) sb.Append('[').Append(LrcParser.FormatTime(t)).Append(']');
            if (line.Words.Count > 0)
                foreach (var w in line.Words) sb.Append('<').Append(LrcParser.FormatTime(w.TimeMs)).Append('>').Append(w.Text);
            else sb.Append(line.Text);
            sb.Append('\n');
        }
        return sb.ToString();
    }

    /// <summary>Returns a copy with all times shifted by <paramref name="deltaMs"/> (positive = later).</summary>
    public LyricsDocument Shift(long deltaMs) => new()
    {
        Lines = Lines.Select(l => l with
        {
            TimeMs = l.TimeMs is { } t ? Math.Max(0, t + deltaMs) : null,
            Words = l.Words.Select(w => w with { TimeMs = Math.Max(0, w.TimeMs + deltaMs) }).ToList()
        }).ToList(),
        IsSynced = IsSynced, OffsetMs = 0, Title = Title, Artist = Artist, Album = Album, Author = Author, LengthMs = LengthMs, Tags = Tags
    };
}

/// <summary>
/// LRC parser supporting multiple timestamps per line ([00:12.00][01:30.50]text), [offset:±ms], metadata tags,
/// enhanced word timing (&lt;00:12.30&gt;word) and plain-text fallback.
/// </summary>
public static partial class LrcParser
{
    [GeneratedRegex(@"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]")]
    private static partial Regex TimeTag();

    [GeneratedRegex(@"^\[([a-zA-Z#]+):(.*)\]\s*$")]
    private static partial Regex MetaTag();

    [GeneratedRegex(@"<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>")]
    private static partial Regex WordTag();

    public static LyricsDocument Parse(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return new LyricsDocument();
        var tags = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var timed = new List<(long Time, int Order, string Text, List<LyricWord> Words)>();
        var plain = new List<string>();
        var order = 0;
        foreach (var raw in text.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n'))
        {
            var line = raw.TrimEnd();
            var trimmed = line.TrimStart();
            var stamps = new List<long>();
            var pos = 0;
            while (true)
            {
                var m = TimeTag().Match(trimmed, pos);
                if (!m.Success || m.Index != pos) break;
                stamps.Add(ToMs(m));
                pos = m.Index + m.Length;
                while (pos < trimmed.Length && trimmed[pos] == ' ' && pos + 1 < trimmed.Length && trimmed[pos + 1] == '[') pos++;
            }
            if (stamps.Count > 0)
            {
                var body = trimmed[pos..];
                var words = ParseWords(body, out var clean);
                foreach (var s in stamps) timed.Add((s, order++, clean, words));
                continue;
            }
            var meta = MetaTag().Match(trimmed);
            if (meta.Success && !TimeTag().IsMatch(trimmed))
            {
                tags[meta.Groups[1].Value.ToLowerInvariant()] = meta.Groups[2].Value.Trim();
                continue;
            }
            plain.Add(line);
        }

        long offset = 0;
        if (tags.TryGetValue("offset", out var off)) long.TryParse(off.Trim().TrimStart('+'), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out offset);
        long? length = tags.TryGetValue("length", out var len) ? ParseLength(len) : null;

        if (timed.Count == 0)
        {
            while (plain.Count > 0 && string.IsNullOrWhiteSpace(plain[0])) plain.RemoveAt(0);
            while (plain.Count > 0 && string.IsNullOrWhiteSpace(plain[^1])) plain.RemoveAt(plain.Count - 1);
            return new LyricsDocument
            {
                Lines = plain.Select(p => new LyricLine(null, p, Array.Empty<LyricWord>())).ToList(),
                IsSynced = false, Tags = tags, Title = tags.GetValueOrDefault("ti"), Artist = tags.GetValueOrDefault("ar"),
                Album = tags.GetValueOrDefault("al"), Author = tags.GetValueOrDefault("by"), LengthMs = length
            };
        }

        // Positive [offset:] makes lyrics appear sooner.
        var lines = timed.OrderBy(t => t.Time).ThenBy(t => t.Order)
            .Select(t => new LyricLine(Math.Max(0, t.Time - offset), t.Text, t.Words.Select(w => w with { TimeMs = Math.Max(0, w.TimeMs - offset) }).ToList()))
            .ToList();
        return new LyricsDocument
        {
            Lines = lines, IsSynced = true, OffsetMs = offset, Tags = tags, Title = tags.GetValueOrDefault("ti"), Artist = tags.GetValueOrDefault("ar"),
            Album = tags.GetValueOrDefault("al"), Author = tags.GetValueOrDefault("by"), LengthMs = length
        };
    }

    private static List<LyricWord> ParseWords(string body, out string clean)
    {
        var words = new List<LyricWord>();
        var matches = WordTag().Matches(body);
        if (matches.Count == 0)
        {
            clean = body.Trim();
            return words;
        }
        for (var i = 0; i < matches.Count; i++)
        {
            var m = matches[i];
            var start = m.Index + m.Length;
            var end = i + 1 < matches.Count ? matches[i + 1].Index : body.Length;
            var word = body[start..end];
            if (word.Length > 0) words.Add(new LyricWord(ToMs(m), word));
        }
        clean = WordTag().Replace(body, "").Trim();
        return words;
    }

    private static long ToMs(Match m)
    {
        var min = long.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture);
        var sec = long.Parse(m.Groups[2].Value, CultureInfo.InvariantCulture);
        long frac = 0;
        if (m.Groups[3].Success)
        {
            var f = m.Groups[3].Value;
            frac = f.Length switch
            {
                1 => long.Parse(f, CultureInfo.InvariantCulture) * 100,
                2 => long.Parse(f, CultureInfo.InvariantCulture) * 10,
                _ => long.Parse(f[..3], CultureInfo.InvariantCulture)
            };
        }
        return (min * 60 + sec) * 1000 + frac;
    }

    private static long? ParseLength(string s)
    {
        var parts = s.Trim().Split(':');
        if (parts.Length == 2 && int.TryParse(parts[0], out var m) && double.TryParse(parts[1], NumberStyles.Float, CultureInfo.InvariantCulture, out var sec))
            return (long)((m * 60 + sec) * 1000);
        return null;
    }

    /// <summary>mm:ss.xx (centiseconds), minutes may exceed 59.</summary>
    public static string FormatTime(long ms)
    {
        if (ms < 0) ms = 0;
        var min = ms / 60000;
        var sec = ms / 1000 % 60;
        var cs = ms % 1000 / 10;
        return $"{min:00}:{sec:00}.{cs:00}";
    }

    /// <summary>True when the text contains at least one LRC timestamp.</summary>
    public static bool LooksSynced(string? text) => text is not null && TimeTag().IsMatch(text);
}
