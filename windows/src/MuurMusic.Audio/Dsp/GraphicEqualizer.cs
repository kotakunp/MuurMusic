using MuurMusic.Core.Models;

namespace MuurMusic.Audio.Dsp;

/// <summary>10-band graphic equalizer: RBJ peaking filters at the ISO frequencies (31 Hz - 16 kHz, Q 1.41, ±12 dB) plus preamp.</summary>
public sealed class GraphicEqualizer
{
    public const int BandCount = 10;
    private readonly BiquadFilter[] _filters = new BiquadFilter[BandCount];
    private readonly double[] _gains = new double[BandCount];
    private int _sampleRate = 48000;
    private int _channels = 2;
    private float _preampLinear = 1f;

    public GraphicEqualizer()
    {
        for (var i = 0; i < BandCount; i++) _filters[i] = new BiquadFilter(_channels);
    }

    public static IReadOnlyList<double> Frequencies => EqPreset.IsoFrequencies;
    public bool Enabled { get; set; }
    public double PreampDb { get; private set; }
    public IReadOnlyList<double> Gains => _gains;
    public bool HasPositiveGain => _gains.Any(g => g > 0) || PreampDb > 0;

    public void Configure(int sampleRate, int channels)
    {
        _sampleRate = sampleRate;
        _channels = channels;
        foreach (var f in _filters) f.SetChannels(channels);
        Recalculate();
    }

    public void Set(double preampDb, IReadOnlyList<double> gains)
    {
        PreampDb = Math.Clamp(preampDb, -EqPreset.MaxGainDb, EqPreset.MaxGainDb);
        _preampLinear = (float)Math.Pow(10, PreampDb / 20);
        for (var i = 0; i < BandCount; i++) _gains[i] = i < gains.Count ? Math.Clamp(gains[i], -EqPreset.MaxGainDb, EqPreset.MaxGainDb) : 0;
        Recalculate();
    }

    private void Recalculate()
    {
        for (var i = 0; i < BandCount; i++)
            _filters[i].Coefficients = BiquadCoefficients.Create(BiquadType.Peaking, _sampleRate, EqPreset.IsoFrequencies[i], EqPreset.BandQ, _gains[i]);
    }

    public void Reset()
    {
        foreach (var f in _filters) f.Reset();
    }

    public void Process(Span<float> interleaved)
    {
        if (!Enabled) return;
        if (_preampLinear != 1f)
            for (var i = 0; i < interleaved.Length; i++) interleaved[i] *= _preampLinear;
        foreach (var f in _filters) f.Process(interleaved);
    }

    /// <summary>Combined magnitude response in dB at <paramref name="frequency"/> (for drawing the EQ curve).</summary>
    public double ResponseDbAt(double frequency)
    {
        var db = PreampDb;
        foreach (var f in _filters) db += f.Coefficients.MagnitudeDbAt(frequency, _sampleRate);
        return db;
    }

    /// <summary>Response curve for arbitrary settings without touching a running instance.</summary>
    public static double ResponseDb(double preampDb, IReadOnlyList<double> gains, double frequency, int sampleRate = 48000)
    {
        var db = preampDb;
        for (var i = 0; i < BandCount && i < gains.Count; i++)
            db += BiquadCoefficients.Create(BiquadType.Peaking, sampleRate, EqPreset.IsoFrequencies[i], EqPreset.BandQ, gains[i]).MagnitudeDbAt(frequency, sampleRate);
        return db;
    }
}
