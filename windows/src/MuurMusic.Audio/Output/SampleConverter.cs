using System.Runtime.InteropServices;

namespace MuurMusic.Audio.Output;

/// <summary>Converts interleaved float samples to the device sample format (render thread). 16-bit output gets TPDF dither at 1 LSB.</summary>
internal static class SampleConverter
{
    private static readonly Random DitherRandom = new();

    public static int Write(ReadOnlySpan<float> source, Span<byte> destination, OutputFormatInfo format)
    {
        var frames = Math.Min(source.Length / format.Channels, destination.Length / format.BlockAlign);
        var samples = frames * format.Channels;
        switch (format.Encoding)
        {
            case OutputSampleEncoding.Float32:
                MemoryMarshal.AsBytes(source.Slice(0, samples)).CopyTo(destination);
                break;
            case OutputSampleEncoding.Int32:
            {
                var dst = MemoryMarshal.Cast<byte, int>(destination);
                for (var i = 0; i < samples; i++) dst[i] = (int)(Math.Clamp(source[i], -1f, 1f) * 2147483647f);
                break;
            }
            case OutputSampleEncoding.Int24In32:
            {
                var dst = MemoryMarshal.Cast<byte, int>(destination);
                for (var i = 0; i < samples; i++) dst[i] = (int)(Math.Clamp(source[i], -1f, 1f) * 8388607f) << 8;
                break;
            }
            case OutputSampleEncoding.Int24:
            {
                var o = 0;
                for (var i = 0; i < samples; i++)
                {
                    var v = (int)(Math.Clamp(source[i], -1f, 1f) * 8388607f);
                    destination[o++] = (byte)v;
                    destination[o++] = (byte)(v >> 8);
                    destination[o++] = (byte)(v >> 16);
                }
                break;
            }
            default:
            {
                var dst = MemoryMarshal.Cast<byte, short>(destination);
                for (var i = 0; i < samples; i++)
                {
                    // TPDF dither: two independent uniform values at half an LSB each.
                    var dither = (float)((DitherRandom.NextDouble() - DitherRandom.NextDouble()) / 32768.0);
                    dst[i] = (short)Math.Clamp((int)MathF.Round(source[i] * 32767f + dither), -32768, 32767);
                }
                break;
            }
        }
        return frames * format.BlockAlign;
    }
}
