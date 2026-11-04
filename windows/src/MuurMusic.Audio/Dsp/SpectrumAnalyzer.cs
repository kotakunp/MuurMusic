using System.Numerics;

namespace MuurMusic.Audio.Dsp;

/// <summary>
/// Visualizer tap: the render thread writes post-DSP mono samples into a ring; the UI thread asks for log-spaced spectrum bands
/// (0..1, smoothed with fast attack / slow decay) or the latest waveform. No locks: a torn read only costs one frame of accuracy.
/// </summary>
public sealed class SpectrumAnalyzer
{
    public const int FftSize = 4096;
    private const int RingSize = 16384;
    private readonly float[] _ring = new float[RingSize];
    private long _writePos;
    private readonly Complex[] _fft = new Complex[FftSize];
    private readonly float[] _window = new float[FftSize];
    private float[] _smoothed = Array.Empty<float>();
    private volatile int _sampleRate = 48000;

    public SpectrumAnalyzer()
    {
        for (var i = 0; i < FftSize; i++) _window[i] = (float)(0.5 - 0.5 * Math.Cos(2 * Math.PI * i / (FftSize - 1)));
    }

    public int SampleRate { get => _sampleRate; set => _sampleRate = value; }
    public float MinDb { get; set; } = -80f;
    public float MaxDb { get; set; } = 0f;
    /// <summary>Per-second decay factor for falling bars (0..1, lower = faster fall).</summary>
    public float Decay { get; set; } = 0.15f;

    /// <summary>Render thread: appends a block (down-mixed to mono).</summary>
    public void Write(ReadOnlySpan<float> interleaved, int channels)
    {
        var pos = _writePos;
        for (var i = 0; i + channels <= interleaved.Length; i += channels)
        {
            var sum = 0f;
            for (var c = 0; c < channels; c++) sum += interleaved[i + c];
            _ring[pos & (RingSize - 1)] = sum / channels;
            pos++;
        }
        Volatile.Write(ref _writePos, pos);
    }

    public void Clear()
    {
        Array.Clear(_ring);
        Array.Clear(_smoothed);
    }

    /// <summary>Copies the most recent <paramref name="output"/>.Length mono samples (oscilloscope).</summary>
    public void GetWaveform(Span<float> output)
    {
        var end = Volatile.Read(ref _writePos);
        var n = Math.Min(output.Length, RingSize);
        var start = end - n;
        for (var i = 0; i < n; i++) output[i] = start + i < 0 ? 0 : _ring[(start + i) & (RingSize - 1)];
    }

    /// <summary>Fills <paramref name="bands"/> with log-spaced band levels between 20 Hz and min(20 kHz, Nyquist), normalized to 0..1.</summary>
    public void GetSpectrum(Span<float> bands, double elapsedSeconds = 1.0 / 60)
    {
        if (bands.Length == 0) return;
        if (_smoothed.Length != bands.Length) _smoothed = new float[bands.Length];
        var end = Volatile.Read(ref _writePos);
        var start = end - FftSize;
        for (var i = 0; i < FftSize; i++)
        {
            var s = start + i < 0 ? 0f : _ring[(start + i) & (RingSize - 1)];
            _fft[i] = new Complex(s * _window[i], 0);
        }
        Fft.Transform(_fft);
        var rate = _sampleRate;
        var nyquist = rate / 2.0;
        var fMin = 20.0;
        var fMax = Math.Min(20000, nyquist);
        var binHz = (double)rate / FftSize;
        const double windowGain = FftSize * 0.5 / 2; // Hann coherent gain, single-sided
        var decay = (float)Math.Pow(Decay, elapsedSeconds);
        for (var b = 0; b < bands.Length; b++)
        {
            var lo = fMin * Math.Pow(fMax / fMin, (double)b / bands.Length);
            var hi = fMin * Math.Pow(fMax / fMin, (double)(b + 1) / bands.Length);
            var i0 = Math.Max(1, (int)Math.Floor(lo / binHz));
            var i1 = Math.Max(i0, Math.Min(FftSize / 2, (int)Math.Ceiling(hi / binHz)));
            double peak = 0;
            for (var i = i0; i <= i1; i++) peak = Math.Max(peak, _fft[i].Magnitude);
            var db = 20 * Math.Log10(Math.Max(peak / windowGain, 1e-9));
            var v = (float)Math.Clamp((db - MinDb) / (MaxDb - MinDb), 0, 1);
            _smoothed[b] = v > _smoothed[b] ? v : Math.Max(v, _smoothed[b] * decay);
            bands[b] = _smoothed[b];
        }
    }
}
