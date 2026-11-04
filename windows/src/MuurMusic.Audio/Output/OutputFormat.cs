using NAudio.Wave;

namespace MuurMusic.Audio.Output;

/// <summary>How samples are delivered to the device.</summary>
public enum OutputSampleEncoding { Float32, Int32, Int24In32, Int24, Int16 }

/// <summary>A negotiated WASAPI stream format.</summary>
public sealed record OutputFormatInfo(int SampleRate, int Channels, OutputSampleEncoding Encoding, int ValidBits, bool Exclusive)
{
    public int BytesPerSample => Encoding switch
    {
        OutputSampleEncoding.Float32 or OutputSampleEncoding.Int32 or OutputSampleEncoding.Int24In32 => 4,
        OutputSampleEncoding.Int24 => 3,
        _ => 2
    };

    public int BlockAlign => BytesPerSample * Channels;

    /// <summary>True when the stream is float at the source's native rate and no DSP alters it (bit-perfect indicator).</summary>
    public bool IsBitPerfectCandidate => Exclusive;

    public override string ToString() =>
        $"{SampleRate / 1000.0:0.#} kHz / {(Encoding == OutputSampleEncoding.Float32 ? "32-bit float" : $"{ValidBits}-bit")} / {Channels} ch" + (Exclusive ? " (exclusive)" : "");

    internal WaveFormat ToWaveFormat()
    {
        var mask = Channels switch
        {
            1 => 0x4,
            2 => 0x3,
            4 => 0x33,
            6 => 0x3F,
            8 => 0x63F,
            _ => (1 << Math.Min(Channels, 18)) - 1
        };
        return Encoding switch
        {
            OutputSampleEncoding.Float32 => WaveFormat.CreateIeeeFloatWaveFormat(SampleRate, Channels),
            OutputSampleEncoding.Int16 => new WaveFormat(SampleRate, 16, Channels),
            OutputSampleEncoding.Int24 => new WaveFormat(SampleRate, 24, Channels),
            OutputSampleEncoding.Int32 => new WaveFormatExtensible(SampleRate, 32, Channels, false, 32, mask),
            _ => new WaveFormatExtensible(SampleRate, 32, Channels, false, 24, mask)
        };
    }
}
