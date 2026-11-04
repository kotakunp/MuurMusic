using MuurMusic.Core.Models;
using MuurMusic.Core.Settings;
using MuurMusic.Audio.Dsp;

namespace MuurMusic.Audio.Tests;

public class DspMiscTests
{
    [Fact]
    public void ReplayGain_Converts_Decibels_To_Linear_Gain()
    {
        var track = new Track { ReplayGainTrackGain = -6.0 };
        Assert.Equal(Math.Pow(10, -6.0 / 20), ReplayGain.LinearGain(track, ReplayGainMode.Track, 0, 0, true), 4);
        Assert.Equal(1.0, ReplayGain.LinearGain(track, ReplayGainMode.Off, 0, 0, true), 6);
        var untagged = new Track();
        Assert.Equal(Math.Pow(10, -3.0 / 20), ReplayGain.LinearGain(untagged, ReplayGainMode.Track, 0, -3.0, true), 4);
    }

    [Fact]
    public void ReplayGain_Prevents_Clipping_From_Peak_Tags()
    {
        var track = new Track { ReplayGainTrackGain = 12.0, ReplayGainTrackPeak = 0.5 };
        Assert.Equal(2.0, ReplayGain.LinearGain(track, ReplayGainMode.Track, 0, 0, true), 4);
        var hot = new Track { ReplayGainTrackGain = 12.0, ReplayGainTrackPeak = 0.9 };
        Assert.Equal(1 / 0.9, ReplayGain.LinearGain(hot, ReplayGainMode.Track, 0, 0, true), 4);
        var allowed = ReplayGain.LinearGain(hot, ReplayGainMode.Track, 0, 0, false);
        Assert.Equal(Math.Pow(10, 12.0 / 20), allowed, 4);
    }

    [Fact]
    public void GraphicEqualizer_Response_Matches_Band_Gains()
    {
        var gains = Enumerable.Repeat(0.0, GraphicEqualizer.BandCount).ToArray();
        gains[0] = 6.0;  // 31 Hz band
        gains[5] = -6.0; // 1 kHz band
        Assert.Equal(6.0, GraphicEqualizer.ResponseDb(0, gains, GraphicEqualizer.Frequencies[0]), 1);
        Assert.Equal(-6.0, GraphicEqualizer.ResponseDb(0, gains, GraphicEqualizer.Frequencies[5]), 1);
        Assert.Equal(0.0, GraphicEqualizer.ResponseDb(0, gains, GraphicEqualizer.Frequencies[9]), 1);
        // Preamp applies everywhere.
        Assert.Equal(3.0, GraphicEqualizer.ResponseDb(-3.0, gains, GraphicEqualizer.Frequencies[0]), 1);

        var eq = new GraphicEqualizer();
        eq.Configure(48000, 2);
        eq.Set(0, gains);
        Assert.True(eq.HasPositiveGain);
        Assert.Equal(6.0, eq.ResponseDbAt(GraphicEqualizer.Frequencies[0]), 1);
    }

    [Fact]
    public void DspProcessor_Eq_Boosts_The_Target_Band()
    {
        var dsp = new DspProcessor();
        dsp.Configure(48000, 2);
        var gains = Enumerable.Repeat(0.0, GraphicEqualizer.BandCount).ToArray();
        gains[5] = 12.0; // 1 kHz band
        dsp.SetEqualizer(true, 0, gains);

        const int frames = 48000;
        var pcm = new float[frames * 2];
        for (var i = 0; i < frames; i++)
        {
            var s = (float)(0.2 * Math.Sin(2 * Math.PI * 1000.0 * i / 48000));
            pcm[i * 2] = s; pcm[i * 2 + 1] = s;
        }
        dsp.Process(pcm);
        Assert.True(dsp.IsActive); // configuration commands drain on the first Process call
        double sum = 0;
        for (var i = frames / 2; i < frames; i++) sum += (double)pcm[i * 2] * pcm[i * 2];
        var outRms = Math.Sqrt(sum / (frames / 2));
        var inRms = 0.2 / Math.Sqrt(2);
        Assert.Equal(inRms * Math.Pow(10, 12.0 / 20), outRms, 1);

        dsp.SetEqualizer(false, 0, gains);
        dsp.Reset();
        var flat = new float[] { 0.5f, 0.5f, -0.5f, -0.5f };
        dsp.Process(flat);
        Assert.Equal(0.5f, flat[0], 5);
    }

    [Fact]
    public void SpectrumAnalyzer_Peak_Tracks_The_Sine_Frequency()
    {
        float[] PeakSpectrum(double freq)
        {
            var analyzer = new SpectrumAnalyzer { SampleRate = 48000 };
            var frames = SpectrumAnalyzer.FftSize;
            var pcm = new float[frames * 2];
            for (var i = 0; i < frames; i++)
            {
                var s = (float)Math.Sin(2 * Math.PI * freq * i / 48000);
                pcm[i * 2] = s; pcm[i * 2 + 1] = s;
            }
            analyzer.Write(pcm, 2);
            var bands = new float[32];
            analyzer.GetSpectrum(bands, elapsedSeconds: 10); // long window -> no decay masking
            return bands;
        }

        var low = PeakSpectrum(500);
        var high = PeakSpectrum(8000);
        var lowPeak = Array.IndexOf(low, low.Max());
        var highPeak = Array.IndexOf(high, high.Max());
        Assert.True(low.Max() > 0.5f, "500 Hz sine should produce a strong band value");
        Assert.True(highPeak > lowPeak, $"8 kHz peak band ({highPeak}) should be above the 500 Hz peak band ({lowPeak})");
    }
}
