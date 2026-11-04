namespace MuurMusic.Core.Tags;

/// <summary>Technical + tag information produced by a media probe (FFmpeg in MuurMusic.Audio).</summary>
public sealed record MediaProbeResult
{
    public TimeSpan Duration { get; init; }
    public int SampleRate { get; init; }
    public int Channels { get; init; }
    public int BitDepth { get; init; }
    public int BitrateKbps { get; init; }
    public string? Codec { get; init; }
    public string? Container { get; init; }
    /// <summary>Container/stream metadata with upper-case keys (TITLE, ARTIST, ALBUM, ...).</summary>
    public IReadOnlyDictionary<string, string> Tags { get; init; } = new Dictionary<string, string>();
    public byte[]? Artwork { get; init; }
    public double? ReplayGainTrackGain { get; init; }
    public double? ReplayGainTrackPeak { get; init; }
    public double? ReplayGainAlbumGain { get; init; }
    public double? ReplayGainAlbumPeak { get; init; }
}

/// <summary>Probes files TagLib# cannot handle (DFF, tracker modules, AC3, TAK, ...) and network streams.</summary>
public interface IMediaProbe
{
    /// <param name="location">Local/UNC path or http(s) URL.</param>
    /// <param name="headers">Optional HTTP headers for URLs.</param>
    Task<MediaProbeResult?> ProbeAsync(string location, IReadOnlyDictionary<string, string>? headers = null, CancellationToken ct = default);
}
