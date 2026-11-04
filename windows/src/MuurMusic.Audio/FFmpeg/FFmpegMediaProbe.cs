using MuurMusic.Core.Tags;

namespace MuurMusic.Audio.FFmpeg;

/// <summary><see cref="IMediaProbe"/> implementation backed by FFmpeg (used by the library scanner for formats TagLib# cannot read).</summary>
public sealed class FFmpegMediaProbe : IMediaProbe
{
    public Task<MediaProbeResult?> ProbeAsync(string location, IReadOnlyDictionary<string, string>? headers = null, CancellationToken ct = default) =>
        Task.Run<MediaProbeResult?>(() =>
        {
            try { return FFmpegDecoder.Probe(location, headers, ct); }
            catch (Decoding.AudioDecoderException) { return null; }
        }, ct);
}
