namespace MuurMusic.Audio.Decoding;

/// <summary>Native properties of a decoded audio stream.</summary>
public sealed record AudioStreamInfo
{
    public int SampleRate { get; init; }
    public int Channels { get; init; }
    /// <summary>Bits per sample of the source (0 when not meaningful, e.g. lossy codecs).</summary>
    public int BitDepth { get; init; }
    public string Codec { get; init; } = "";
    public string? Container { get; init; }
    public TimeSpan Duration { get; init; }
    public int BitrateKbps { get; init; }
    /// <summary>True for DSD sources (decoded to PCM at 1/8 of the DSD rate by FFmpeg).</summary>
    public bool IsDsd { get; init; }
    public bool IsLossless { get; init; }
}

/// <summary>
/// Decodes audio to interleaved 32-bit float frames. Implementations are used from one thread at a time;
/// <see cref="Abort"/> may be called from any thread to unblock pending network reads.
/// </summary>
public interface IAudioDecoder : IDisposable
{
    AudioStreamInfo Info { get; }
    /// <summary>Output sample rate after <see cref="SetOutputFormat"/> (defaults to the native rate).</summary>
    int OutputSampleRate { get; }
    /// <summary>Output channel count after <see cref="SetOutputFormat"/> (defaults to the native count).</summary>
    int OutputChannels { get; }
    bool CanSeek { get; }
    /// <summary>Set when decoding stopped because of an I/O or decode error rather than the end of the stream.</summary>
    string? Error { get; }
    /// <summary>Selects the output format (resampling / channel mapping as needed). Call before the first <see cref="Read"/>, or after a seek.</summary>
    void SetOutputFormat(int sampleRate, int channels);
    /// <summary>Fills <paramref name="buffer"/> (length a multiple of <see cref="OutputChannels"/>) and returns the number of frames written; 0 = end of stream.</summary>
    int Read(Span<float> buffer);
    /// <summary>Sample-accurate seek (relative to the start of the stream).</summary>
    void Seek(TimeSpan position);
    void Abort();
}

/// <summary>Thrown when a stream cannot be opened or decoded.</summary>
public sealed class AudioDecoderException(string message, Exception? inner = null) : Exception(message, inner);
