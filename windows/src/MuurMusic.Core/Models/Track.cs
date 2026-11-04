namespace MuurMusic.Core.Models;

/// <summary>
/// A playable track known to the library (or created ad hoc from a source listing).
/// Virtual CUE tracks share <see cref="SourceUri"/> with their image file and differ by <see cref="CueStartMs"/>.
/// </summary>
public sealed class Track
{
    public long Id { get; set; }
    public string SourceUri { get; set; } = "";
    public Guid? SourceId { get; set; }
    /// <summary>Local or UNC path when the file is directly reachable through the file system.</summary>
    public string? FilePath { get; set; }
    public string? Folder { get; set; }
    public string FileName { get; set; } = "";

    public long CueStartMs { get; set; }
    public long? CueEndMs { get; set; }
    public string? CueSheetPath { get; set; }

    public string? Title { get; set; }
    public string? Artist { get; set; }
    public string? Album { get; set; }
    public string? AlbumArtist { get; set; }
    public string? Genre { get; set; }
    public string? Composer { get; set; }
    public int? Year { get; set; }
    public int? TrackNumber { get; set; }
    public int? TrackTotal { get; set; }
    public int? DiscNumber { get; set; }
    public int? DiscTotal { get; set; }
    public int? Bpm { get; set; }
    public string? Comment { get; set; }
    public bool HasLyrics { get; set; }

    /// <summary>0 (unrated) to 5 stars.</summary>
    public int Rating { get; set; }
    public int PlayCount { get; set; }
    public int SkipCount { get; set; }
    public DateTimeOffset? LastPlayed { get; set; }
    public DateTimeOffset DateAdded { get; set; } = DateTimeOffset.UtcNow;
    public bool Favorite { get; set; }

    public long DurationMs { get; set; }
    /// <summary>Average bitrate in kbit/s.</summary>
    public int Bitrate { get; set; }
    public int SampleRate { get; set; }
    /// <summary>Bits per sample for PCM-based codecs (0 for lossy codecs where it is meaningless; 1 for DSD).</summary>
    public int BitDepth { get; set; }
    public int Channels { get; set; }
    /// <summary>Codec name such as FLAC, ALAC, MP3, AAC, DSD.</summary>
    public string? Codec { get; set; }
    /// <summary>Container / file format (usually the lower-case extension without dot).</summary>
    public string? Format { get; set; }
    public long FileSize { get; set; }
    /// <summary>Last write time of the file (unix ms) used for incremental rescans.</summary>
    public long FileModifiedMs { get; set; }
    public string? ArtworkHash { get; set; }

    public double? ReplayGainTrackGain { get; set; }
    public double? ReplayGainTrackPeak { get; set; }
    public double? ReplayGainAlbumGain { get; set; }
    public double? ReplayGainAlbumPeak { get; set; }

    public bool IsRemote { get; set; }
    /// <summary>Path of a downloaded offline copy, if any.</summary>
    public string? LocalCopyPath { get; set; }
    public string? MusicBrainzRecordingId { get; set; }
    public string? MusicBrainzReleaseId { get; set; }
    public bool IsUnavailable { get; set; }

    /// <summary>Remote artwork URL for media-server items that are not in the artwork cache.</summary>
    public string? ArtworkUrl { get; set; }

    public TimeSpan Duration => TimeSpan.FromMilliseconds(DurationMs);
    public bool IsCueTrack => CueEndMs.HasValue || CueStartMs > 0;
    public string DisplayTitle => string.IsNullOrWhiteSpace(Title) ? Path.GetFileNameWithoutExtension(FileName) : Title!;
    public string DisplayArtist => string.IsNullOrWhiteSpace(Artist) ? (string.IsNullOrWhiteSpace(AlbumArtist) ? "Unknown artist" : AlbumArtist!) : Artist!;
    public string DisplayAlbum => string.IsNullOrWhiteSpace(Album) ? "Unknown album" : Album!;
    public string EffectiveAlbumArtist => string.IsNullOrWhiteSpace(AlbumArtist) ? DisplayArtist : AlbumArtist!;

    public bool IsLossless => AudioFormats.IsLosslessCodec(Codec);
    public bool IsHiRes => IsLossless && (BitDepth > 16 || SampleRate > 48000);

    /// <summary>Human readable quality badge, e.g. "FLAC 24/96" or "MP3 320k".</summary>
    public string QualityBadge => AudioFormats.FormatBadge(Codec ?? Format, BitDepth, SampleRate, Bitrate);

    /// <summary>Identity across library and playlists: source URI plus CUE offset.</summary>
    public string Key => CueStartMs > 0 || CueEndMs.HasValue ? $"{SourceUri}#t={CueStartMs}" : SourceUri;

    public Track Clone() => (Track)MemberwiseClone();
}
