namespace MuurMusic.Core.Models;

/// <summary>Album aggregate derived from tracks (grouped by album artist + album name).</summary>
public sealed record Album(
    string Key,
    string Name,
    string AlbumArtist,
    int? Year,
    string? Genre,
    int TrackCount,
    int DiscCount,
    long DurationMs,
    string? ArtworkHash,
    int MaxBitDepth,
    int MaxSampleRate,
    string? Codec,
    DateTimeOffset DateAdded,
    int PlayCount)
{
    public bool IsHiRes => AudioFormats.IsLosslessCodec(Codec) && (MaxBitDepth > 16 || MaxSampleRate > 48000);
    public TimeSpan Duration => TimeSpan.FromMilliseconds(DurationMs);
}

/// <summary>Artist (or album artist) aggregate.</summary>
public sealed record Artist(string Name, int AlbumCount, int TrackCount, long DurationMs, string? ArtworkHash);

/// <summary>Genre aggregate.</summary>
public sealed record Genre(string Name, int AlbumCount, int TrackCount, string? ArtworkHash);

/// <summary>Composer aggregate.</summary>
public sealed record Composer(string Name, int AlbumCount, int TrackCount, string? ArtworkHash);

/// <summary>A folder in the library folder tree (derived from track paths).</summary>
public sealed record LibraryFolder(string Path, string Name, int TrackCount, bool HasSubfolders);

/// <summary>Listing of one level of the library folder tree.</summary>
public sealed record FolderContents(string Path, IReadOnlyList<LibraryFolder> Folders, IReadOnlyList<Track> Tracks);

/// <summary>Library-wide statistics.</summary>
public sealed record LibraryStats(int TrackCount, int AlbumCount, int ArtistCount, long TotalDurationMs, long TotalBytes);
