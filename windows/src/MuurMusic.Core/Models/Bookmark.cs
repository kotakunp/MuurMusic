namespace MuurMusic.Core.Models;

/// <summary>A saved position inside a track.</summary>
public sealed class Bookmark
{
    public long Id { get; set; }
    public long? TrackId { get; set; }
    public string SourceUri { get; set; } = "";
    public long CueStartMs { get; set; }
    public long PositionMs { get; set; }
    public string? Note { get; set; }
    public DateTimeOffset Created { get; set; } = DateTimeOffset.UtcNow;
    public string? TrackTitle { get; set; }
    public string? TrackArtist { get; set; }
    public TimeSpan Position => TimeSpan.FromMilliseconds(PositionMs);
}

/// <summary>One play event.</summary>
public sealed class PlayHistoryEntry
{
    public long Id { get; set; }
    public long? TrackId { get; set; }
    public string SourceUri { get; set; } = "";
    public DateTimeOffset PlayedAt { get; set; }
    public long PlayedMs { get; set; }
    public bool Completed { get; set; }
    public string? Title { get; set; }
    public string? Artist { get; set; }
}

public enum DownloadState { Queued, Downloading, Paused, Completed, Failed, Canceled }

public enum DownloadKind
{
    /// <summary>User requested offline copy (kept until removed).</summary>
    Offline,
    /// <summary>Automatic cache of a recently played remote song (evicted LRU).</summary>
    Cache,
    /// <summary>Plain file download to a user-chosen folder.</summary>
    Export
}

/// <summary>A download manager item (persisted across restarts).</summary>
public sealed class DownloadItem
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string SourceUri { get; set; } = "";
    public long? TrackId { get; set; }
    public string Title { get; set; } = "";
    public string? Artist { get; set; }
    public string DestinationPath { get; set; } = "";
    public long TotalBytes { get; set; }
    public long DownloadedBytes { get; set; }
    public DownloadState State { get; set; }
    public DownloadKind Kind { get; set; }
    public string? Error { get; set; }
    public int Attempts { get; set; }
    public DateTimeOffset Created { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset Updated { get; set; } = DateTimeOffset.UtcNow;
    /// <summary>Bytes per second, measured over the last second (not persisted).</summary>
    public double BytesPerSecond { get; set; }
    public double Progress => TotalBytes > 0 ? Math.Clamp((double)DownloadedBytes / TotalBytes, 0, 1) : 0;
    public DownloadItem Clone() => (DownloadItem)MemberwiseClone();
}
