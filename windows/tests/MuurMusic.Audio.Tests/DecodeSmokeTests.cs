using System.Diagnostics;
using MuurMusic.Audio.Decoding;
using MuurMusic.Audio.FFmpeg;

namespace MuurMusic.Audio.Tests;

public class DecodeSmokeTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "muur-decode-" + Guid.NewGuid().ToString("N"));
    private static readonly string Ffmpeg = FindFfmpeg();

    private static string FindFfmpeg()
    {
        var path = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var dir in path.Split(Path.PathSeparator))
        {
            if (string.IsNullOrWhiteSpace(dir)) continue;
            var candidate = Path.Combine(dir.Trim(), "ffmpeg.exe");
            if (File.Exists(candidate)) return candidate;
        }
        throw new FileNotFoundException("ffmpeg.exe was not found on PATH; it is required to generate the decode test fixtures.");
    }

    private string Generate(string fileName, double freq = 440, double seconds = 1.0, int rate = 48000)
    {
        Directory.CreateDirectory(_dir);
        var output = Path.Combine(_dir, fileName);
        var psi = new ProcessStartInfo(Ffmpeg,
            $"-hide_banner -loglevel error -y -f lavfi -i \"sine=frequency={freq}:duration={seconds}:sample_rate={rate}\" -ac 2 \"{output}\"")
        { RedirectStandardError = true, RedirectStandardOutput = true };
        using var p = Process.Start(psi)!;
        p.WaitForExit(30_000);
        Assert.True(p.ExitCode == 0, "ffmpeg failed: " + p.StandardError.ReadToEnd());
        return output;
    }

    private static (float[] Samples, int Frames, AudioStreamInfo Info) DecodeAll(string path)
    {
        FFmpegLoader.EnsureLoaded();
        using var dec = FFmpegDecoder.OpenFile(path);
        var samples = new List<float>();
        var block = new float[8192];
        int n;
        while ((n = dec.Read(block)) > 0) samples.AddRange(block.AsSpan(0, n * dec.OutputChannels).ToArray());
        return (samples.ToArray(), samples.Count / dec.OutputChannels, dec.Info);
    }

    private static double DominantFrequency(float[] pcm, int channels, int rate)
    {
        var crossings = 0;
        for (var i = channels; i < pcm.Length; i += channels)
            if (pcm[i - channels] < 0 && pcm[i] >= 0) crossings++;
        return crossings / ((double)pcm.Length / channels / rate);
    }

    [Fact]
    public void Decodes_Wav_Sine_With_Correct_Length_And_Frequency()
    {
        var file = Generate("tone.wav");
        var (samples, frames, info) = DecodeAll(file);
        Assert.Equal(48000, frames);
        Assert.Equal(48000, info.SampleRate);
        Assert.Equal(2, info.Channels);
        Assert.Equal("PCM", info.Codec);
        Assert.True(info.IsLossless);
        Assert.InRange(DominantFrequency(samples, info.Channels, info.SampleRate), 437, 443);
    }

    [Fact]
    public void Decodes_Flac_Sine_With_Correct_Length_And_Frequency()
    {
        var file = Generate("tone.flac", freq: 1000, seconds: 2.0);
        var (samples, frames, info) = DecodeAll(file);
        Assert.Equal(96000, frames);
        Assert.Equal("FLAC", info.Codec);
        Assert.True(info.IsLossless);
        Assert.InRange(info.Duration.TotalSeconds, 1.99, 2.01);
        Assert.InRange(DominantFrequency(samples, info.Channels, info.SampleRate), 995, 1005);
    }

    [Fact]
    public void Seek_Is_Sample_Accurate_Enough()
    {
        var file = Generate("seek.flac", seconds: 2.0);
        FFmpegLoader.EnsureLoaded();
        using var dec = FFmpegDecoder.OpenFile(file);
        dec.Seek(TimeSpan.FromSeconds(1));
        var samples = new List<float>();
        var block = new float[8192];
        int n;
        while ((n = dec.Read(block)) > 0) samples.AddRange(block.AsSpan(0, n * dec.OutputChannels).ToArray());
        var frames = samples.Count / dec.OutputChannels;
        Assert.InRange(frames, 48000 - 64, 48000 + 64);
    }

    public void Dispose()
    {
        try { Directory.Delete(_dir, true); } catch { /* temp cleanup is best-effort */ }
    }
}
