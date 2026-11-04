using System.Numerics;

namespace MuurMusic.Audio.Dsp;

/// <summary>In-place iterative radix-2 FFT.</summary>
public static class Fft
{
    public static void Transform(Span<Complex> data, bool inverse = false)
    {
        var n = data.Length;
        if (n == 0 || (n & (n - 1)) != 0) throw new ArgumentException("FFT length must be a power of two.", nameof(data));
        for (int i = 1, j = 0; i < n; i++)
        {
            var bit = n >> 1;
            for (; (j & bit) != 0; bit >>= 1) j ^= bit;
            j ^= bit;
            if (i < j) (data[i], data[j]) = (data[j], data[i]);
        }
        for (var len = 2; len <= n; len <<= 1)
        {
            var ang = 2 * Math.PI / len * (inverse ? 1 : -1);
            var wl = new Complex(Math.Cos(ang), Math.Sin(ang));
            for (var i = 0; i < n; i += len)
            {
                var w = Complex.One;
                var half = len >> 1;
                for (var k = 0; k < half; k++)
                {
                    var u = data[i + k];
                    var v = data[i + k + half] * w;
                    data[i + k] = u + v;
                    data[i + k + half] = u - v;
                    w *= wl;
                }
            }
        }
        if (inverse)
            for (var i = 0; i < n; i++) data[i] /= n;
    }

    /// <summary>Magnitude spectrum (bins 0..n/2) of a real signal with a Hann window, normalized so a full-scale sine is ~1.0.</summary>
    public static float[] MagnitudeSpectrum(ReadOnlySpan<float> samples)
    {
        var n = samples.Length;
        var buf = new Complex[n];
        double windowSum = 0;
        for (var i = 0; i < n; i++)
        {
            var w = 0.5 - 0.5 * Math.Cos(2 * Math.PI * i / (n - 1));
            windowSum += w;
            buf[i] = new Complex(samples[i] * w, 0);
        }
        Transform(buf);
        var result = new float[n / 2 + 1];
        for (var i = 0; i <= n / 2; i++) result[i] = (float)(2 * buf[i].Magnitude / windowSum);
        return result;
    }
}
