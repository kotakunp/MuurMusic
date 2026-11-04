using MuurMusic.Audio.Dsp;

namespace MuurMusic.Audio.Tests;

public class BiquadTests
{
    private const double Rate = 48000.0;

    [Fact]
    public void Peaking_At_Center_Frequency_Matches_Gain()
    {
        var c = BiquadCoefficients.Create(BiquadType.Peaking, Rate, 1000, 1.0, 6.0);
        Assert.Equal(6.0, c.MagnitudeDbAt(1000, Rate), 2);
        Assert.Equal(0.0, c.MagnitudeDbAt(20, Rate), 1);
        Assert.Equal(0.0, c.MagnitudeDbAt(24000, Rate), 1);
        // Octave away the skirt has mostly decayed for Q=1.
        Assert.InRange(Math.Abs(c.MagnitudeDbAt(250, Rate)), 0, 2.0);
        Assert.InRange(Math.Abs(c.MagnitudeDbAt(4000, Rate)), 0, 2.0);
    }

    [Fact]
    public void Peaking_Cut_Is_Reciprocal_Of_Boost()
    {
        var boost = BiquadCoefficients.Create(BiquadType.Peaking, Rate, 500, 2.0, 9.0);
        var cut = BiquadCoefficients.Create(BiquadType.Peaking, Rate, 500, 2.0, -9.0);
        Assert.Equal(9.0, boost.MagnitudeDbAt(500, Rate), 2);
        Assert.Equal(-9.0, cut.MagnitudeDbAt(500, Rate), 2);
    }

    [Fact]
    public void LowPass_Matches_Rbj_Cookbook_Coefficients()
    {
        const double f0 = 1000, q = 0.70710678;
        var c = BiquadCoefficients.Create(BiquadType.LowPass, Rate, f0, q);
        // Independent re-computation of the RBJ audio EQ cookbook formulas.
        double w0 = 2 * Math.PI * f0 / Rate, alpha = Math.Sin(w0) / (2 * q), cosw = Math.Cos(w0);
        double b0 = (1 - cosw) / 2, b1 = 1 - cosw, b2 = (1 - cosw) / 2, a0 = 1 + alpha, a1 = -2 * cosw, a2 = 1 - alpha;
        Assert.Equal(b0 / a0, c.B0, 10);
        Assert.Equal(b1 / a0, c.B1, 10);
        Assert.Equal(b2 / a0, c.B2, 10);
        Assert.Equal(a1 / a0, c.A1, 10);
        Assert.Equal(a2 / a0, c.A2, 10);
        Assert.Equal(1.0, c.MagnitudeAt(1, Rate), 3);               // DC passes
        Assert.Equal(0.0, c.MagnitudeAt(Rate / 2, Rate), 3);        // Nyquist rejected
        Assert.Equal(-3.01, c.MagnitudeDbAt(f0, Rate), 1);          // -3 dB at cutoff for Butterworth Q
    }

    [Fact]
    public void HighPass_And_Shelves_Behave_At_Extremes()
    {
        var hp = BiquadCoefficients.Create(BiquadType.HighPass, Rate, 1000, 0.70710678);
        Assert.True(hp.MagnitudeDbAt(1, Rate) < -60);
        Assert.Equal(-3.01, hp.MagnitudeDbAt(1000, Rate), 1);
        Assert.Equal(0.0, hp.MagnitudeDbAt(Rate / 2, Rate), 2);

        var lowShelf = BiquadCoefficients.Create(BiquadType.LowShelf, Rate, 200, 0.9, 12.0);
        Assert.Equal(12.0, lowShelf.MagnitudeDbAt(1, Rate), 1);
        Assert.Equal(0.0, lowShelf.MagnitudeDbAt(Rate / 2, Rate), 1);

        var notch = BiquadCoefficients.Create(BiquadType.Notch, Rate, 1000, 4.0);
        Assert.True(notch.MagnitudeDbAt(1000, Rate) < -40);
        Assert.Equal(0.0, notch.MagnitudeDbAt(20, Rate), 1);
    }

    [Fact]
    public void Filter_Amplifies_Sine_At_Center_Frequency()
    {
        var c = BiquadCoefficients.Create(BiquadType.Peaking, Rate, 1000, 1.0, 6.0);
        var filter = new BiquadFilter(2) { Coefficients = c };
        const int frames = 96000;
        var pcm = new float[frames * 2];
        for (var i = 0; i < frames; i++)
        {
            var s = (float)(0.5 * Math.Sin(2 * Math.PI * 1000.0 * i / Rate));
            pcm[i * 2] = s; pcm[i * 2 + 1] = s;
        }
        filter.Process(pcm);
        // Steady-state output RMS should be 10^(6/20) times the input RMS.
        double sum = 0;
        for (var i = frames / 2; i < frames; i++) sum += (double)pcm[i * 2] * pcm[i * 2];
        var outRms = Math.Sqrt(sum / (frames / 2));
        var inRms = 0.5 / Math.Sqrt(2);
        Assert.Equal(inRms * Math.Pow(10, 6.0 / 20), outRms, 2);
    }

    [Fact]
    public void Filter_Is_Mono_Compatible_And_Resettable()
    {
        var filter = new BiquadFilter(1) { Coefficients = BiquadCoefficients.Create(BiquadType.HighPass, Rate, 1000, 0.7) };
        var dc = new float[48000];
        Array.Fill(dc, 0.5f);
        filter.Process(dc);
        Assert.True(Math.Abs(dc[^1]) < 1e-4); // high-pass removes DC
        filter.Reset();
        Assert.Equal(0f, filter.ProcessSample(0f, 0));
    }
}
