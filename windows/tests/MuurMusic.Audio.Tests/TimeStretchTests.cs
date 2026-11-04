using MuurMusic.Audio.Dsp;

namespace MuurMusic.Audio.Tests;

public class TimeStretchTests
{
    private static float[] MakeSine(double seconds, double freq, int rate = 48000, int channels = 2)
    {
        var frames = (int)(seconds * rate);
        var pcm = new float[frames * channels];
        for (var i = 0; i < frames; i++)
        {
            var s = (float)(0.6 * Math.Sin(2 * Math.PI * freq * i / rate));
            for (var c = 0; c < channels; c++) pcm[i * channels + c] = s;
        }
        return pcm;
    }

    private static float[] StretchAll(float[] input, int channels, double speed)
    {
        var ts = new WsolaTimeStretcher(48000, channels) { Speed = speed };
        var cursor = 0;
        var output = new List<float>();
        var block = new float[8192];
        while (true)
        {
            var n = ts.Process(block, dst =>
            {
                var frames = Math.Min(dst.Length / channels, (input.Length - cursor) / channels);
                input.AsSpan(cursor, frames * channels).CopyTo(dst);
                cursor += frames * channels;
                return frames; // 0 = end of input
            });
            if (n > 0) output.AddRange(block.AsSpan(0, n * channels).ToArray());
            if (ts.Finished) break;
            Assert.True(output.Count < 40_000_000, "time stretcher did not terminate");
        }
        return output.ToArray();
    }

    private static double DominantFrequency(float[] pcm, int channels, int rate)
    {
        var crossings = 0;
        for (var i = channels; i < pcm.Length; i += channels)
            if (pcm[i - channels] < 0 && pcm[i] >= 0) crossings++;
        var seconds = (double)pcm.Length / channels / rate;
        return crossings / seconds;
    }

    [Theory]
    [InlineData(0.5)]
    [InlineData(0.75)]
    [InlineData(1.25)]
    [InlineData(1.5)]
    [InlineData(2.0)]
    public void Output_Length_Scales_With_Inverse_Speed(double speed)
    {
        var input = MakeSine(2.0, 440);
        var output = StretchAll(input, 2, speed);
        var inFrames = input.Length / 2;
        var outFrames = output.Length / 2;
        var expected = inFrames / speed;
        Assert.InRange(outFrames, expected * 0.9, expected * 1.1);
    }

    [Fact]
    public void Pitch_Is_Preserved()
    {
        var input = MakeSine(2.0, 440);
        var output = StretchAll(input, 2, 1.5);
        var freq = DominantFrequency(output, 2, 48000);
        Assert.InRange(freq, 425, 455);
    }
}
