namespace MuurMusic.Audio.Dsp;

/// <summary>Peak and RMS levels of the last rendered block (linear 0..1+; dB helpers provided).</summary>
public readonly record struct MeterReading(float PeakLeft, float PeakRight, float RmsLeft, float RmsRight)
{
    public static float ToDb(float linear) => 20f * MathF.Log10(Math.Max(linear, 1e-6f));
    public float PeakDb => ToDb(Math.Max(PeakLeft, PeakRight));
}

/// <summary>Computes per-block peak/RMS on the render thread; readers get the latest values with peak hold and decay.</summary>
public sealed class AudioMeter
{
    private float _peakL, _peakR, _rmsL, _rmsR;
    private float _heldL, _heldR;
    private long _lastReadTicks = Environment.TickCount64;

    public void Process(ReadOnlySpan<float> interleaved, int channels)
    {
        if (channels <= 0 || interleaved.Length < channels) return;
        float pl = 0, pr = 0;
        double sl = 0, sr = 0;
        var frames = interleaved.Length / channels;
        for (var i = 0; i + channels <= interleaved.Length; i += channels)
        {
            var l = interleaved[i];
            var r = channels > 1 ? interleaved[i + 1] : l;
            var al = MathF.Abs(l);
            var ar = MathF.Abs(r);
            if (al > pl) pl = al;
            if (ar > pr) pr = ar;
            sl += l * l;
            sr += r * r;
        }
        Volatile.Write(ref _peakL, Math.Max(Volatile.Read(ref _peakL), pl));
        Volatile.Write(ref _peakR, Math.Max(Volatile.Read(ref _peakR), pr));
        Volatile.Write(ref _rmsL, (float)Math.Sqrt(sl / frames));
        Volatile.Write(ref _rmsR, (float)Math.Sqrt(sr / frames));
    }

    /// <summary>Returns levels since the previous read; peaks fall back at ~20 dB/s for smooth meters.</summary>
    public MeterReading Read()
    {
        var now = Environment.TickCount64;
        var dt = Math.Clamp((now - _lastReadTicks) / 1000f, 0f, 1f);
        _lastReadTicks = now;
        var decay = MathF.Pow(10, -20f * dt / 20f);
        var pl = Interlocked.Exchange(ref _peakL, 0f);
        var pr = Interlocked.Exchange(ref _peakR, 0f);
        _heldL = Math.Max(pl, _heldL * decay);
        _heldR = Math.Max(pr, _heldR * decay);
        return new MeterReading(_heldL, _heldR, Volatile.Read(ref _rmsL), Volatile.Read(ref _rmsR));
    }

    public void Reset()
    {
        _peakL = _peakR = _rmsL = _rmsR = _heldL = _heldR = 0;
    }
}
