using System.Diagnostics;
using MuurMusic.Core.Models;
using MuurMusic.Core.Tags;
using MuurMusic.Audio.Decoding;
using MuurMusic.Audio.Engine;

namespace MuurMusic.Audio.Tests;

/// <summary>In-memory sine-wave decoder used to feed the engine without files.</summary>
internal sealed class SineDecoder : IAudioDecoder
{
    private readonly int _rate, _channels;
    private readonly double _freq, _phase;
    private readonly long _totalFrames;
    private long _pos;

    public SineDecoder(double freq, double seconds, int rate = 48000, int channels = 2, double phase = 0)
    {
        _freq = freq; _phase = phase; _rate = rate; _channels = channels;
        _totalFrames = (long)(seconds * rate);
        Info = new AudioStreamInfo
        {
            Codec = "sine", Container = "sine", SampleRate = rate, Channels = channels,
            Duration = TimeSpan.FromSeconds(seconds), IsLossless = true
        };
    }

    public AudioStreamInfo Info { get; }
    public int OutputSampleRate => _rate;
    public int OutputChannels => _channels;
    public bool CanSeek => true;
    public string? Error => null;

    public void SetOutputFormat(int sampleRate, int channels)
    {
        if (sampleRate != _rate || channels != _channels)
            throw new NotSupportedException("SineDecoder only serves its native format.");
    }

    public int Read(Span<float> buffer)
    {
        var frames = (int)Math.Min(buffer.Length / _channels, _totalFrames - _pos);
        for (var i = 0; i < frames; i++)
        {
            var s = (float)(0.5 * Math.Sin(_phase + 2 * Math.PI * _freq * (_pos + i) / _rate));
            for (var c = 0; c < _channels; c++) buffer[i * _channels + c] = s;
        }
        _pos += frames;
        return frames;
    }

    public void Seek(TimeSpan position) => _pos = Math.Clamp((long)(position.TotalSeconds * _rate), 0, _totalFrames);
    public void Abort() { }
    public void Dispose() { }
}

public class GaplessTests
{
    private const int Rate = 48000, Channels = 2;

    private static (TrackSource Source, SineDecoder Decoder) MakeSource(double freq, double seconds = 1.0, double phase = 0)
    {
        var dec = new SineDecoder(freq, seconds, Rate, Channels, phase);
        var track = new Track { Title = $"{freq} Hz", DurationMs = (long)(seconds * 1000) };
        var src = new TrackSource(track, Guid.NewGuid(), dec, Rate, Channels, gain: 1f, bufferSeconds: 0.5);
        src.Start();
        return (src, dec);
    }

    private sealed class Harness : IDisposable
    {
        public readonly AudioEngine Engine = new();
        public readonly List<EngineTrackEventArgs> Started = new();
        public readonly List<EngineTrackFinishedEventArgs> Finished = new();
        public readonly ManualResetEventSlim Ended = new();
        public readonly List<float> Rendered = new();

        public Harness()
        {
            Engine.Configure(Rate, Channels);
            Engine.TrackStarted += (_, e) => Started.Add(e);
            Engine.TrackFinished += (_, e) => Finished.Add(e);
            Engine.Ended += (_, _) => Ended.Set();
        }

        public void RenderToEnd(int blockFrames = 480)
        {
            var block = new float[blockFrames * Channels];
            var sw = Stopwatch.StartNew();
            while (sw.Elapsed < TimeSpan.FromSeconds(60))
            {
                Engine.Render(block);
                if (Engine.State == EngineState.Stopped) break;
                if (Engine.IsBuffering) { Thread.Sleep(2); continue; } // nothing was consumed; discard
                Rendered.AddRange(block);
                if (Ended.IsSet && Engine.State == EngineState.Stopped) break;
            }
            Assert.True(Ended.Wait(TimeSpan.FromSeconds(10)), "engine never raised Ended");
        }

        public int RenderedFrames => Rendered.Count / Channels;
        public void Dispose() => Engine.Dispose();
    }

    // Per-window RMS: immune to legitimate zero crossings of a sine wave, but any real gap
    // of >= one window produces a (near-)zero window.
    private static double MinWindowRms(List<float> pcm, int channels, int startFrame, int endFrameExclusive, int window = 64)
    {
        var min = double.MaxValue;
        for (var f = startFrame; f + window <= endFrameExclusive && f + window <= pcm.Count / channels; f += window)
        {
            double sum = 0;
            for (var i = 0; i < window; i++) sum += (double)pcm[(f + i) * channels] * pcm[(f + i) * channels];
            min = Math.Min(min, Math.Sqrt(sum / window));
        }
        return min;
    }

    private static double FrequencyIn(List<float> pcm, int channels, int startFrame, int endFrameExclusive)
    {
        var crossings = 0;
        for (var f = startFrame + 1; f < endFrameExclusive; f++)
            if (pcm[(f - 1) * channels] < 0 && pcm[f * channels] >= 0) crossings++;
        return crossings / ((endFrameExclusive - startFrame) / (double)Rate);
    }

    [Fact]
    public void Gapless_Transition_Has_No_Silence_At_The_Boundary()
    {
        using var h = new Harness();
        var (s1, _) = MakeSource(440);
        // A non-zero phase keeps the first sample of the second track off the zero line.
        var (s2, _) = MakeSource(880, phase: Math.PI / 2);
        h.Engine.Play(s1);
        h.Engine.SetNext(s2);
        h.RenderToEnd();

        const int framesPerTrack = Rate * 1; // 1 s each
        Assert.True(h.RenderedFrames >= framesPerTrack * 2, $"expected at least {framesPerTrack * 2} frames, got {h.RenderedFrames}");
        var minRms = MinWindowRms(h.Rendered, Channels, 64, framesPerTrack * 2 - 64);
        Assert.True(minRms > 0.01, $"found silence inside the gapless transition (min window RMS {minRms})");
        Assert.InRange(FrequencyIn(h.Rendered, Channels, 2_000, 46_000), 437, 443);
        Assert.InRange(FrequencyIn(h.Rendered, Channels, framesPerTrack + 2_000, framesPerTrack * 2 - 2_000), 875, 885);

        Assert.Equal(2, h.Started.Count);
        Assert.Equal(TrackTransition.Manual, h.Started[0].Transition);
        Assert.Equal(TrackTransition.Gapless, h.Started[1].Transition);
        Assert.Equal(2, h.Finished.Count);
        Assert.All(h.Finished, f => Assert.True(f.Completed));
    }

    [Fact]
    public void Gap_Adds_Configured_Silence_Between_Tracks()
    {
        using var h = new Harness();
        h.Engine.Gapless = false;
        h.Engine.GapMilliseconds = 100; // 4800 frames
        var (s1, _) = MakeSource(440);
        var (s2, _) = MakeSource(880);
        h.Engine.Play(s1);
        h.Engine.SetNext(s2);
        h.RenderToEnd();

        const int framesPerTrack = Rate;
        var gapRms = MinWindowRms(h.Rendered, Channels, framesPerTrack, framesPerTrack + 4_800);
        Assert.True(gapRms < 1e-6, $"expected a ~100 ms gap, min window RMS was {gapRms}");
        Assert.Equal(2, h.Started.Count);
        Assert.Equal(TrackTransition.Gapless, h.Started[1].Transition);
    }

    [Fact]
    public void Crossfade_Overlaps_The_Two_Tracks()
    {
        using var h = new Harness();
        h.Engine.CrossfadeSeconds = 0.2; // 9600 frames of overlap
        var (s1, _) = MakeSource(440);
        var (s2, _) = MakeSource(880, phase: Math.PI / 2);
        h.Engine.Play(s1);
        h.Engine.SetNext(s2);
        h.RenderToEnd();

        var overlap = (int)(0.2 * Rate);
        var audibleEnd = Rate + overlap; // second track starts 0.2 s before the first ends
        var minRms = MinWindowRms(h.Rendered, Channels, 64, audibleEnd - 64);
        Assert.True(minRms > 0.01, $"found silence inside the crossfade (min window RMS {minRms})");
        Assert.Equal(2, h.Started.Count);
        Assert.Equal(TrackTransition.Crossfade, h.Started[1].Transition);
        // Both frequencies must be present in the middle of the overlap.
        var mid = Rate - overlap / 2;
        var window = 2_048;
        var start = mid - window / 2;
        var slice = Enumerable.Range(0, window).Select(i => h.Rendered[(start + i) * Channels]).ToArray();
        var g440 = Goertzel(slice, window, 440);
        var g880 = Goertzel(slice, window, 880);
        Assert.True(g440 > 0.05, $"440 Hz missing during crossfade (power {g440:F4}, 880 power {g880:F4})");
        Assert.True(g880 > 0.05, $"880 Hz missing during crossfade (power {g880:F4}, 440 power {g440:F4})");
    }

    private static double Goertzel(float[] samples, int n, double freq)
    {
        var k = (int)(0.5 + n * freq / Rate);
        var w = 2 * Math.PI * k / n;
        double c = 2 * Math.Cos(w), s0 = 0, s1 = 0, s2 = 0;
        for (var i = 0; i < n; i++) { s0 = samples[i] + c * s1 - s2; s2 = s1; s1 = s0; }
        var power = s1 * s1 + s2 * s2 - c * s1 * s2;
        return Math.Sqrt(Math.Max(power, 0)) / (n / 2.0);
    }
}
