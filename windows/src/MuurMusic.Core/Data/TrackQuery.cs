namespace MuurMusic.Core.Data;

public enum TrackSortField
{
    Title, Album, Artist, AlbumArtist, Genre, Composer, Rating, Year, Bpm, PlayCount, Bitrate, Duration, DateAdded, LastPlayed,
    FileName, Path, TrackNumber, Random
}

public enum AlbumSortField { Name, Artist, Year, DateAdded, PlayCount, Duration, Random }

/// <summary>Filter + sort + paging for track listings. All filters are optional and combined with AND.</summary>
public sealed record TrackQuery
{
    /// <summary>Smart search text (prefix match per word over title/artist/album/album artist/genre/composer/path, diacritic-insensitive).</summary>
    public string? Search { get; init; }
    public string? Artist { get; init; }
    public string? AlbumArtist { get; init; }
    public string? AlbumKey { get; init; }
    public string? Genre { get; init; }
    public string? Composer { get; init; }
    public string? Folder { get; init; }
    public bool IncludeSubfolders { get; init; }
    public bool FavoritesOnly { get; init; }
    public int? MinRating { get; init; }
    public Guid? SourceId { get; init; }
    /// <summary>Hide remote tracks without an offline copy or cache entry (offline mode).</summary>
    public bool AvailableOnly { get; init; }
    public TrackSortField Sort { get; init; } = TrackSortField.Title;
    public bool Descending { get; init; }
    public int Offset { get; init; }
    /// <summary>0 = no limit.</summary>
    public int Limit { get; init; }
}

public sealed record AlbumQuery
{
    public string? Search { get; init; }
    /// <summary>Matches album artist or track artist.</summary>
    public string? Artist { get; init; }
    public string? Genre { get; init; }
    public string? Composer { get; init; }
    public bool AvailableOnly { get; init; }
    public AlbumSortField Sort { get; init; } = AlbumSortField.Name;
    public bool Descending { get; init; }
    public int Offset { get; init; }
    public int Limit { get; init; }
}

/// <summary>SQL fragments shared by track listings and smart playlists.</summary>
internal static class TrackSql
{
    public const string AvailableFilter = "(t.is_remote = 0 OR t.local_copy_path IS NOT NULL OR EXISTS (SELECT 1 FROM audio_cache c WHERE c.source_uri = t.source_uri))";

    private const string AlbumOrder = "t.album_key, coalesce(t.disc_number, 1), coalesce(t.track_number, 0), t.cue_start_ms, t.file_name COLLATE NOCASE";

    public static string OrderBy(TrackSortField field, bool desc)
    {
        var d = desc ? " DESC" : "";
        return field switch
        {
            TrackSortField.Title => $"t.title IS NULL, coalesce(t.title, t.file_name) COLLATE NOCASE{d}, t.file_name COLLATE NOCASE",
            TrackSortField.Album => $"(t.album IS NULL OR t.album = ''), t.album COLLATE NOCASE{d}, {AlbumOrder}",
            TrackSortField.Artist => $"(t.artist IS NULL OR t.artist = ''), t.artist COLLATE NOCASE{d}, t.album COLLATE NOCASE, {AlbumOrder}",
            TrackSortField.AlbumArtist => $"coalesce(nullif(t.album_artist, ''), t.artist) IS NULL, coalesce(nullif(t.album_artist, ''), t.artist) COLLATE NOCASE{d}, t.year, t.album COLLATE NOCASE, {AlbumOrder}",
            TrackSortField.Genre => $"(t.genre IS NULL OR t.genre = ''), t.genre COLLATE NOCASE{d}, t.artist COLLATE NOCASE, {AlbumOrder}",
            TrackSortField.Composer => $"(t.composer IS NULL OR t.composer = ''), t.composer COLLATE NOCASE{d}, t.title COLLATE NOCASE",
            TrackSortField.Rating => $"t.rating{d}, t.title COLLATE NOCASE",
            TrackSortField.Year => $"t.year IS NULL, t.year{d}, t.album COLLATE NOCASE, {AlbumOrder}",
            TrackSortField.Bpm => $"t.bpm IS NULL, t.bpm{d}, t.title COLLATE NOCASE",
            TrackSortField.PlayCount => $"t.play_count{d}, t.last_played DESC, t.title COLLATE NOCASE",
            TrackSortField.Bitrate => $"t.bitrate{d}, t.title COLLATE NOCASE",
            TrackSortField.Duration => $"t.duration_ms{d}, t.title COLLATE NOCASE",
            TrackSortField.DateAdded => $"t.date_added{d}, {AlbumOrder}",
            TrackSortField.LastPlayed => $"t.last_played IS NULL, t.last_played{d}",
            TrackSortField.FileName => $"t.file_name COLLATE NOCASE{d}",
            TrackSortField.Path => $"coalesce(t.file_path, t.source_uri) COLLATE NOCASE{d}, t.cue_start_ms",
            TrackSortField.TrackNumber => $"{AlbumOrder}",
            TrackSortField.Random => "random()",
            _ => "t.id"
        };
    }

    public static bool TryParseSort(string? text, out TrackSortField field, out bool desc)
    {
        field = TrackSortField.Title;
        desc = false;
        if (string.IsNullOrWhiteSpace(text)) return false;
        var s = text.Trim();
        if (s.StartsWith('-')) { desc = true; s = s[1..]; }
        if (s.EndsWith(" desc", StringComparison.OrdinalIgnoreCase)) { desc = true; s = s[..^5].Trim(); }
        else if (s.EndsWith(" asc", StringComparison.OrdinalIgnoreCase)) s = s[..^4].Trim();
        s = s switch
        {
            "length" => "duration",
            "added" => "dateAdded",
            "plays" => "playCount",
            _ => s
        };
        return Enum.TryParse(s, ignoreCase: true, out field);
    }

    /// <summary>Builds an FTS5 MATCH expression with prefix matching for each word; null when no searchable token.</summary>
    public static string? BuildFtsQuery(string? search)
    {
        if (string.IsNullOrWhiteSpace(search)) return null;
        var tokens = new List<string>();
        var sb = new System.Text.StringBuilder();
        foreach (var ch in search)
        {
            if (char.IsLetterOrDigit(ch) || char.GetUnicodeCategory(ch) is System.Globalization.UnicodeCategory.NonSpacingMark) sb.Append(ch);
            else if (sb.Length > 0) { tokens.Add(sb.ToString()); sb.Clear(); }
        }
        if (sb.Length > 0) tokens.Add(sb.ToString());
        if (tokens.Count == 0) return null;
        return string.Join(' ', tokens.Select(t => "\"" + t.Replace("\"", "\"\"") + "\"*"));
    }
}
