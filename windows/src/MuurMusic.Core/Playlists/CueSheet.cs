using System.Globalization;
using System.Text;
using MuurMusic.Core.Models;

namespace MuurMusic.Core.Playlists;

public sealed class CueTrack
{
    public int Number { get; set; }
    public string Type { get; set; } = "AUDIO";
    public string? Title { get; set; }
    public string? Performer { get; set; }
    public string? Songwriter { get; set; }
    public string? Isrc { get; set; }
    /// <summary>INDEX 00 (pregap start) in CD frames (75 per second), if present.</summary>
    public long? Index00Frames { get; set; }
    /// <summary>INDEX 01 (track start) in CD frames.</summary>
    public long Index01Frames { get; set; }
    public Dictionary<string, string> Rem { get; } = new(StringComparer.OrdinalIgnoreCase);
    public string FileName { get; set; } = "";
    public long StartMs => CueSheet.FramesToMs(Index01Frames);
}

public sealed class CueFile
{
    public string FileName { get; set; } = "";
    public string FileType { get; set; } = "WAVE";
    public List<CueTrack> Tracks { get; } = new();
}

/// <summary>A virtual track produced from a CUE sheet.</summary>
public sealed record CueVirtualTrack(string AudioFile, int Number, long StartMs, long? EndMs, string? Title, string? Performer, string? Songwriter,
    string? AlbumTitle, string? AlbumPerformer, string? Genre, string? Date, int TrackCount, string? Isrc);

/// <summary>CUE sheet model with parser and writer (FILE / TRACK nn AUDIO / INDEX 01 mm:ss:ff at 75 frames/s).</summary>
public sealed class CueSheet
{
    public const int FramesPerSecond = 75;

    public string? Title { get; set; }
    public string? Performer { get; set; }
    public string? Songwriter { get; set; }
    public string? Catalog { get; set; }
    public string? CdTextFile { get; set; }
    public Dictionary<string, string> Rem { get; } = new(StringComparer.OrdinalIgnoreCase);
    public List<CueFile> Files { get; } = new();

    public string? Genre => Rem.GetValueOrDefault("GENRE");
    public string? Date => Rem.GetValueOrDefault("DATE");
    public IEnumerable<CueTrack> AllTracks => Files.SelectMany(f => f.Tracks);

    public static long FramesToMs(long frames) => frames * 1000 / FramesPerSecond;
    public static long MsToFrames(long ms) => (long)Math.Round(ms * FramesPerSecond / 1000.0);

    /// <summary>Parses "mm:ss:ff" (minutes may exceed 99) into frames.</summary>
    public static long ParseMsf(string text)
    {
        var parts = text.Trim().Split(':');
        if (parts.Length != 3) throw new FormatException($"Invalid CUE time '{text}'.");
        var m = long.Parse(parts[0], CultureInfo.InvariantCulture);
        var s = long.Parse(parts[1], CultureInfo.InvariantCulture);
        var f = long.Parse(parts[2], CultureInfo.InvariantCulture);
        if (s >= 60 || f >= FramesPerSecond) throw new FormatException($"Invalid CUE time '{text}'.");
        return (m * 60 + s) * FramesPerSecond + f;
    }

    public static string FormatMsf(long frames)
    {
        var f = frames % FramesPerSecond;
        var totalSeconds = frames / FramesPerSecond;
        return $"{totalSeconds / 60:00}:{totalSeconds % 60:00}:{f:00}";
    }

    public static CueSheet Load(string path) => Parse(M3uFormat.DecodeText(File.ReadAllBytes(path), false));

    public static CueSheet Parse(string text)
    {
        var sheet = new CueSheet();
        CueFile? file = null;
        CueTrack? track = null;
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Trim().TrimStart('\uFEFF');
            if (line.Length == 0) continue;
            var (cmd, rest) = SplitCommand(line);
            switch (cmd)
            {
                case "REM":
                {
                    var (key, value) = SplitCommand(rest);
                    if (key.Length == 0) break;
                    var v = Unquote(value);
                    if (track is not null) track.Rem[key] = v; else sheet.Rem[key] = v;
                    break;
                }
                case "TITLE":
                    if (track is not null) track.Title = Unquote(rest); else sheet.Title = Unquote(rest);
                    break;
                case "PERFORMER":
                    if (track is not null) track.Performer = Unquote(rest); else sheet.Performer = Unquote(rest);
                    break;
                case "SONGWRITER":
                    if (track is not null) track.Songwriter = Unquote(rest); else sheet.Songwriter = Unquote(rest);
                    break;
                case "CATALOG": sheet.Catalog = Unquote(rest); break;
                case "CDTEXTFILE": sheet.CdTextFile = Unquote(rest); break;
                case "ISRC": if (track is not null) track.Isrc = Unquote(rest); break;
                case "FILE":
                {
                    var (name, type) = SplitQuotedAndRest(rest);
                    file = new CueFile { FileName = name, FileType = type.Length > 0 ? type.ToUpperInvariant() : "WAVE" };
                    sheet.Files.Add(file);
                    track = null;
                    break;
                }
                case "TRACK":
                {
                    if (file is null) { file = new CueFile(); sheet.Files.Add(file); }
                    var parts = rest.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                    track = new CueTrack
                    {
                        Number = parts.Length > 0 && int.TryParse(parts[0], out var n) ? n : file.Tracks.Count + 1,
                        Type = parts.Length > 1 ? parts[1].ToUpperInvariant() : "AUDIO",
                        FileName = file.FileName
                    };
                    file.Tracks.Add(track);
                    break;
                }
                case "INDEX":
                {
                    if (track is null) break;
                    var parts = rest.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                    if (parts.Length < 2) break;
                    var idx = int.Parse(parts[0], CultureInfo.InvariantCulture);
                    var frames = ParseMsf(parts[1]);
                    if (idx == 0) track.Index00Frames = frames;
                    else if (idx == 1) track.Index01Frames = frames;
                    break;
                }
            }
        }
        return sheet;
    }

    private static (string Cmd, string Remainder) SplitCommand(string line)
    {
        var sp = line.IndexOfAny(new[] { ' ', '\t' });
        return sp < 0 ? (line.ToUpperInvariant(), "") : (line[..sp].ToUpperInvariant(), line[(sp + 1)..].Trim());
    }

    private static (string Quoted, string Remainder) SplitQuotedAndRest(string s)
    {
        s = s.Trim();
        if (s.StartsWith('"'))
        {
            var end = s.IndexOf('"', 1);
            if (end > 0) return (s[1..end], s[(end + 1)..].Trim());
        }
        var sp = s.LastIndexOf(' ');
        return sp < 0 ? (s, "") : (s[..sp].Trim(), s[(sp + 1)..].Trim());
    }

    private static string Unquote(string s)
    {
        s = s.Trim();
        return s.Length >= 2 && s[0] == '"' && s[^1] == '"' ? s[1..^1] : s;
    }

    /// <summary>
    /// Expands the sheet into virtual tracks. A track ends at the next track's INDEX 01 within the same FILE, or at the
    /// end of the file (EndMs = null). <paramref name="resolveFile"/> maps FILE names to real paths (null = keep name).
    /// </summary>
    public IReadOnlyList<CueVirtualTrack> ToVirtualTracks(Func<string, string?>? resolveFile = null)
    {
        var result = new List<CueVirtualTrack>();
        var audioTracks = AllTracks.Count(t => t.Type == "AUDIO");
        foreach (var f in Files)
        {
            var path = resolveFile?.Invoke(f.FileName) ?? f.FileName;
            var tracks = f.Tracks.Where(t => t.Type == "AUDIO").ToList();
            for (var i = 0; i < tracks.Count; i++)
            {
                var t = tracks[i];
                long? end = null;
                if (i + 1 < tracks.Count)
                    end = FramesToMs(tracks[i + 1].Index01Frames);
                result.Add(new CueVirtualTrack(path, t.Number, t.StartMs, end, t.Title, t.Performer ?? Performer, t.Songwriter ?? Songwriter,
                    Title, Performer, t.Rem.GetValueOrDefault("GENRE") ?? Genre, Date, audioTracks, t.Isrc));
            }
        }
        return result;
    }

    public string Write()
    {
        var sb = new StringBuilder();
        foreach (var (k, v) in Rem) sb.Append("REM ").Append(k.ToUpperInvariant()).Append(' ').Append(NeedsQuotes(v) ? Quote(v) : v).Append("\r\n");
        if (Catalog is not null) sb.Append("CATALOG ").Append(Catalog).Append("\r\n");
        if (Performer is not null) sb.Append("PERFORMER ").Append(Quote(Performer)).Append("\r\n");
        if (Songwriter is not null) sb.Append("SONGWRITER ").Append(Quote(Songwriter)).Append("\r\n");
        if (Title is not null) sb.Append("TITLE ").Append(Quote(Title)).Append("\r\n");
        foreach (var f in Files)
        {
            sb.Append("FILE ").Append(Quote(f.FileName)).Append(' ').Append(f.FileType).Append("\r\n");
            foreach (var t in f.Tracks)
            {
                sb.Append("  TRACK ").Append(t.Number.ToString("00", CultureInfo.InvariantCulture)).Append(' ').Append(t.Type).Append("\r\n");
                if (t.Title is not null) sb.Append("    TITLE ").Append(Quote(t.Title)).Append("\r\n");
                if (t.Performer is not null) sb.Append("    PERFORMER ").Append(Quote(t.Performer)).Append("\r\n");
                if (t.Songwriter is not null) sb.Append("    SONGWRITER ").Append(Quote(t.Songwriter)).Append("\r\n");
                if (t.Isrc is not null) sb.Append("    ISRC ").Append(t.Isrc).Append("\r\n");
                foreach (var (k, v) in t.Rem) sb.Append("    REM ").Append(k.ToUpperInvariant()).Append(' ').Append(NeedsQuotes(v) ? Quote(v) : v).Append("\r\n");
                if (t.Index00Frames is { } i0) sb.Append("    INDEX 00 ").Append(FormatMsf(i0)).Append("\r\n");
                sb.Append("    INDEX 01 ").Append(FormatMsf(t.Index01Frames)).Append("\r\n");
            }
        }
        return sb.ToString();
    }

    private static bool NeedsQuotes(string v) => v.Contains(' ') || v.Length == 0;
    private static string Quote(string v) => "\"" + v.Replace("\"", "'") + "\"";

    public static string FileTypeFor(string path) => Path.GetExtension(path).ToLowerInvariant() switch
    {
        ".mp3" => "MP3",
        ".aif" or ".aiff" => "AIFF",
        ".wav" => "WAVE",
        _ => "WAVE"
    };

    /// <summary>Builds a CUE sheet that lists <paramref name="tracks"/> (one FILE per source file, relative names when possible).</summary>
    public static CueSheet FromTracks(IEnumerable<Track> tracks, string cuePath, string? title = null)
    {
        var sheet = new CueSheet { Title = title };
        var number = 1;
        CueFile? current = null;
        foreach (var t in tracks)
        {
            var location = M3uFormat.LocationFor(t, cuePath);
            if (current is null || !string.Equals(current.FileName, location, StringComparison.OrdinalIgnoreCase))
            {
                current = new CueFile { FileName = location, FileType = FileTypeFor(location) };
                sheet.Files.Add(current);
            }
            current.Tracks.Add(new CueTrack
            {
                Number = number++, Title = t.DisplayTitle, Performer = t.DisplayArtist, Songwriter = t.Composer,
                Index01Frames = MsToFrames(t.CueStartMs), FileName = location
            });
        }
        var albums = sheet.AllTracks.Select(x => x.Performer).Distinct().ToList();
        if (albums.Count == 1) sheet.Performer = albums[0];
        return sheet;
    }

    /// <summary>Finds the audio file a CUE FILE line refers to, tolerating a wrong extension (e.g. .wav renamed to .flac).</summary>
    public static string? ResolveAudioFile(string cueDirectory, string fileName)
    {
        var candidate = Path.IsPathFullyQualified(fileName) ? fileName : Path.Combine(cueDirectory, fileName.Replace('/', Path.DirectorySeparatorChar));
        if (File.Exists(candidate)) return candidate;
        var dir = Path.GetDirectoryName(candidate) ?? cueDirectory;
        var stem = Path.GetFileNameWithoutExtension(candidate);
        if (!Directory.Exists(dir)) return null;
        foreach (var f in Directory.EnumerateFiles(dir, stem + ".*"))
            if (AudioFormats.IsAudioFile(f) && string.Equals(Path.GetFileNameWithoutExtension(f), stem, StringComparison.OrdinalIgnoreCase))
                return f;
        return null;
    }
}
