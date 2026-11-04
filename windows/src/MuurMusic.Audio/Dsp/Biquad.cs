using System.Numerics;

namespace MuurMusic.Audio.Dsp;

public enum BiquadType { LowPass, HighPass, BandPass, Notch, Peaking, LowShelf, HighShelf, AllPass }

/// <summary>Normalized biquad coefficients (a0 = 1) computed with the RBJ Audio EQ Cookbook formulas.</summary>
public readonly record struct BiquadCoefficients(double B0, double B1, double B2, double A1, double A2)
{
    public static readonly BiquadCoefficients Identity = new(1, 0, 0, 0, 0);

    public bool IsIdentity => B0 == 1 && B1 == 0 && B2 == 0 && A1 == 0 && A2 == 0;

    /// <summary>RBJ cookbook design. <paramref name="gainDb"/> is used by peaking and shelving filters only.</summary>
    public static BiquadCoefficients Create(BiquadType type, double sampleRate, double frequency, double q, double gainDb = 0)
    {
        if (sampleRate <= 0) throw new ArgumentOutOfRangeException(nameof(sampleRate));
        frequency = Math.Clamp(frequency, 1, sampleRate * 0.4999);
        q = Math.Max(q, 1e-3);
        var a = Math.Pow(10, gainDb / 40);
        var w0 = 2 * Math.PI * frequency / sampleRate;
        var cos = Math.Cos(w0);
        var sin = Math.Sin(w0);
        var alpha = sin / (2 * q);
        double b0, b1, b2, a0, a1, a2;
        switch (type)
        {
            case BiquadType.LowPass:
                b0 = (1 - cos) / 2; b1 = 1 - cos; b2 = (1 - cos) / 2;
                a0 = 1 + alpha; a1 = -2 * cos; a2 = 1 - alpha;
                break;
            case BiquadType.HighPass:
                b0 = (1 + cos) / 2; b1 = -(1 + cos); b2 = (1 + cos) / 2;
                a0 = 1 + alpha; a1 = -2 * cos; a2 = 1 - alpha;
                break;
            case BiquadType.BandPass:
                b0 = alpha; b1 = 0; b2 = -alpha;
                a0 = 1 + alpha; a1 = -2 * cos; a2 = 1 - alpha;
                break;
            case BiquadType.Notch:
                b0 = 1; b1 = -2 * cos; b2 = 1;
                a0 = 1 + alpha; a1 = -2 * cos; a2 = 1 - alpha;
                break;
            case BiquadType.AllPass:
                b0 = 1 - alpha; b1 = -2 * cos; b2 = 1 + alpha;
                a0 = 1 + alpha; a1 = -2 * cos; a2 = 1 - alpha;
                break;
            case BiquadType.Peaking:
                if (gainDb == 0) return Identity;
                b0 = 1 + alpha * a; b1 = -2 * cos; b2 = 1 - alpha * a;
                a0 = 1 + alpha / a; a1 = -2 * cos; a2 = 1 - alpha / a;
                break;
            case BiquadType.LowShelf:
            {
                if (gainDb == 0) return Identity;
                var s = 2 * Math.Sqrt(a) * alpha;
                b0 = a * ((a + 1) - (a - 1) * cos + s);
                b1 = 2 * a * ((a - 1) - (a + 1) * cos);
                b2 = a * ((a + 1) - (a - 1) * cos - s);
                a0 = (a + 1) + (a - 1) * cos + s;
                a1 = -2 * ((a - 1) + (a + 1) * cos);
                a2 = (a + 1) + (a - 1) * cos - s;
                break;
            }
            case BiquadType.HighShelf:
            {
                if (gainDb == 0) return Identity;
                var s = 2 * Math.Sqrt(a) * alpha;
                b0 = a * ((a + 1) + (a - 1) * cos + s);
                b1 = -2 * a * ((a - 1) + (a + 1) * cos);
                b2 = a * ((a + 1) + (a - 1) * cos - s);
                a0 = (a + 1) - (a - 1) * cos + s;
                a1 = 2 * ((a - 1) - (a + 1) * cos);
                a2 = (a + 1) - (a - 1) * cos - s;
                break;
            }
            default:
                throw new ArgumentOutOfRangeException(nameof(type));
        }
        return new BiquadCoefficients(b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0);
    }

    /// <summary>Complex frequency response H(e^jw) at <paramref name="frequency"/>.</summary>
    public Complex ResponseAt(double frequency, double sampleRate)
    {
        var w = 2 * Math.PI * frequency / sampleRate;
        var z1 = Complex.FromPolarCoordinates(1, -w);
        var z2 = z1 * z1;
        return (B0 + B1 * z1 + B2 * z2) / (1 + A1 * z1 + A2 * z2);
    }

    public double MagnitudeAt(double frequency, double sampleRate) => ResponseAt(frequency, sampleRate).Magnitude;

    public double MagnitudeDbAt(double frequency, double sampleRate) => 20 * Math.Log10(Math.Max(MagnitudeAt(frequency, sampleRate), 1e-12));
}

/// <summary>Multi-channel biquad filter (transposed direct form II, double-precision state) processing interleaved samples.</summary>
public sealed class BiquadFilter
{
    private double[] _z1 = Array.Empty<double>(), _z2 = Array.Empty<double>();

    public BiquadFilter(int channels) => SetChannels(channels);

    public BiquadCoefficients Coefficients { get; set; } = BiquadCoefficients.Identity;
    public int Channels { get; private set; }

    public void SetChannels(int channels)
    {
        Channels = Math.Max(1, channels);
        _z1 = new double[Channels];
        _z2 = new double[Channels];
    }

    public void Reset()
    {
        Array.Clear(_z1);
        Array.Clear(_z2);
    }

    public void Process(Span<float> interleaved)
    {
        var c = Coefficients;
        if (c.IsIdentity) return;
        var ch = Channels;
        double b0 = c.B0, b1 = c.B1, b2 = c.B2, a1 = c.A1, a2 = c.A2;
        for (var k = 0; k < ch; k++)
        {
            double z1 = _z1[k], z2 = _z2[k];
            for (var i = k; i < interleaved.Length; i += ch)
            {
                double x = interleaved[i];
                var y = b0 * x + z1;
                z1 = b1 * x - a1 * y + z2;
                z2 = b2 * x - a2 * y;
                interleaved[i] = (float)y;
            }
            // Flush denormals so silence after loud passages does not cost CPU.
            _z1[k] = Math.Abs(z1) < 1e-20 ? 0 : z1;
            _z2[k] = Math.Abs(z2) < 1e-20 ? 0 : z2;
        }
    }

    /// <summary>Processes a single sample of channel <paramref name="channel"/>.</summary>
    public float ProcessSample(float input, int channel)
    {
        var c = Coefficients;
        double x = input;
        var y = c.B0 * x + _z1[channel];
        _z1[channel] = c.B1 * x - c.A1 * y + _z2[channel];
        _z2[channel] = c.B2 * x - c.A2 * y;
        return (float)y;
    }
}
