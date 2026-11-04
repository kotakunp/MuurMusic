using MuurMusic.Core.Models;

namespace MuurMusic.Audio.Dsp;

/// <summary>A DSP chain node processor. All methods are called on the audio render thread except construction.</summary>
public interface IDspEffect
{
    string Type { get; }
    /// <summary>Allocates buffers for the sample rate / channel count. May be called again when the output format changes.</summary>
    void Configure(int sampleRate, int channels);
    /// <summary>Applies node parameters (no allocations).</summary>
    void SetParams(DspNode node);
    void Process(Span<float> interleaved);
    void Reset();
}

/// <summary>Creates processors for the node types of the shared muur-dsp format.</summary>
public static class DspEffectFactory
{
    public static IDspEffect Create(string type) => type switch
    {
        DspNodeTypes.LowPass => new BiquadEffect(type, BiquadType.LowPass),
        DspNodeTypes.HighPass => new BiquadEffect(type, BiquadType.HighPass),
        DspNodeTypes.BandPass => new BiquadEffect(type, BiquadType.BandPass),
        DspNodeTypes.Notch => new BiquadEffect(type, BiquadType.Notch),
        DspNodeTypes.Peaking => new BiquadEffect(type, BiquadType.Peaking),
        DspNodeTypes.LowShelf => new BiquadEffect(type, BiquadType.LowShelf),
        DspNodeTypes.HighShelf => new BiquadEffect(type, BiquadType.HighShelf),
        DspNodeTypes.Gain => new GainEffect(),
        DspNodeTypes.SoftClip => new SoftClipEffect(),
        DspNodeTypes.BitCrusher => new BitCrusherEffect(),
        DspNodeTypes.Tremolo => new TremoloEffect(),
        DspNodeTypes.Delay => new DelayEffect(),
        DspNodeTypes.RingModulator => new RingModulatorEffect(),
        DspNodeTypes.StereoWidth => new StereoWidthEffect(),
        DspNodeTypes.Reverb => new ReverbEffect(),
        DspNodeTypes.Chorus => new ModulatedDelayEffect(type, 7, 25, 0.5),
        DspNodeTypes.Flanger => new ModulatedDelayEffect(type, 0.5, 6, 0.25),
        DspNodeTypes.Phaser => new PhaserEffect(),
        DspNodeTypes.AutoWah => new AutoWahEffect(),
        DspNodeTypes.Distortion => new DistortionEffect(),
        DspNodeTypes.Compressor => new CompressorEffect(),
        DspNodeTypes.Crossfeed => new CrossfeedEffect(),
        _ => new PassthroughEffect(type)
    };
}

internal abstract class EffectBase(string type) : IDspEffect
{
    protected int SampleRate = 48000;
    protected int Channels = 2;
    public string Type { get; } = type;

    public virtual void Configure(int sampleRate, int channels)
    {
        SampleRate = sampleRate;
        Channels = Math.Max(1, channels);
    }

    public abstract void SetParams(DspNode node);
    public abstract void Process(Span<float> interleaved);
    public virtual void Reset() { }
}

/// <summary>Unknown node types from newer app versions: kept in the chain, audio passes through.</summary>
internal sealed class PassthroughEffect(string type) : EffectBase(type)
{
    public override void SetParams(DspNode node) { }
    public override void Process(Span<float> interleaved) { }
}

internal sealed class BiquadEffect(string type, BiquadType kind) : EffectBase(type)
{
    private readonly BiquadFilter _filter = new(2);
    private double _freq = 1000, _q = 0.707, _gain;

    public override void Configure(int sampleRate, int channels)
    {
        base.Configure(sampleRate, channels);
        _filter.SetChannels(Channels);
        Update();
    }

    public override void SetParams(DspNode node)
    {
        _freq = node.Get("frequencyHz");
        _q = node.Get("q");
        _gain = node.Get("gainDb");
        Update();
    }

    private void Update() => _filter.Coefficients = BiquadCoefficients.Create(kind, SampleRate, _freq, _q, _gain);
    public override void Process(Span<float> interleaved) => _filter.Process(interleaved);
    public override void Reset() => _filter.Reset();
}

internal sealed class GainEffect() : EffectBase(DspNodeTypes.Gain)
{
    private float _gain = 1f;
    public override void SetParams(DspNode node) => _gain = (float)Math.Pow(10, node.Get("gainDb") / 20);

    public override void Process(Span<float> interleaved)
    {
        if (_gain == 1f) return;
        for (var i = 0; i < interleaved.Length; i++) interleaved[i] *= _gain;
    }
}

internal sealed class SoftClipEffect() : EffectBase(DspNodeTypes.SoftClip)
{
    private float _k = 3.7f, _norm = 1f;

    public override void SetParams(DspNode node)
    {
        _k = 1f + (float)node.Get("drive") * 9f;
        _norm = 1f / MathF.Tanh(_k);
    }

    public override void Process(Span<float> interleaved)
    {
        for (var i = 0; i < interleaved.Length; i++) interleaved[i] = MathF.Tanh(_k * interleaved[i]) * _norm;
    }
}

internal sealed class BitCrusherEffect() : EffectBase(DspNodeTypes.BitCrusher)
{
    private float _levels = 128;
    private int _downsample = 1;
    private int _counter;
    private float[] _held = new float[2];

    public override void Configure(int sampleRate, int channels)
    {
        base.Configure(sampleRate, channels);
        _held = new float[Channels];
    }

    public override void SetParams(DspNode node)
    {
        var bits = Math.Clamp((int)Math.Round(node.Get("bits")), 1, 16);
        _levels = MathF.Pow(2, bits - 1);
        _downsample = Math.Clamp((int)Math.Round(node.Get("downsample")), 1, 32);
    }

    public override void Process(Span<float> interleaved)
    {
        var ch = Channels;
        for (var i = 0; i + ch <= interleaved.Length; i += ch)
        {
            if (_counter == 0)
                for (var c = 0; c < ch; c++) _held[c] = MathF.Round(interleaved[i + c] * _levels) / _levels;
            _counter = (_counter + 1) % _downsample;
            for (var c = 0; c < ch; c++) interleaved[i + c] = _held[c];
        }
    }

    public override void Reset() => _counter = 0;
}

internal sealed class TremoloEffect() : EffectBase(DspNodeTypes.Tremolo)
{
    private double _phase, _rate = 5, _depth = 0.5;

    public override void SetParams(DspNode node)
    {
        _rate = node.Get("rateHz");
        _depth = node.Get("depth");
    }

    public override void Process(Span<float> interleaved)
    {
        var inc = 2 * Math.PI * _rate / SampleRate;
        var ch = Channels;
        for (var i = 0; i + ch <= interleaved.Length; i += ch)
        {
            var g = (float)(1 - _depth * (0.5 + 0.5 * Math.Sin(_phase)));
            for (var c = 0; c < ch; c++) interleaved[i + c] *= g;
            _phase += inc;
            if (_phase > 2 * Math.PI) _phase -= 2 * Math.PI;
        }
    }

    public override void Reset() => _phase = 0;
}

internal sealed class DelayEffect() : EffectBase(DspNodeTypes.Delay)
{
    private const double MaxSeconds = 2.0;
    private float[] _buffer = Array.Empty<float>();
    private int _frames, _pos, _delayFrames = 1;
    private float _feedback = 0.35f, _mix = 0.3f;
    private double _timeMs = 350;

    public override void Configure(int sampleRate, int channels)
    {
        base.Configure(sampleRate, channels);
        _frames = (int)(sampleRate * MaxSeconds) + 1;
        _buffer = new float[_frames * Channels];
        _pos = 0;
        UpdateDelay();
    }

    public override void SetParams(DspNode node)
    {
        _timeMs = node.Get("timeMs");
        _feedback = (float)Math.Clamp(node.Get("feedback"), 0, 0.95);
        _mix = (float)Math.Clamp(node.Get("mix"), 0, 1);
        UpdateDelay();
    }

    private void UpdateDelay() => _delayFrames = Math.Clamp((int)(_timeMs * SampleRate / 1000), 1, Math.Max(1, _frames - 1));

    public override void Process(Span<float> interleaved)
    {
        if (_buffer.Length == 0) return;
        var ch = Channels;
        for (var i = 0; i + ch <= interleaved.Length; i += ch)
        {
            var read = (_pos - _delayFrames + _frames) % _frames;
            for (var c = 0; c < ch; c++)
            {
                var x = interleaved[i + c];
                var d = _buffer[read * ch + c];
                _buffer[_pos * ch + c] = x + d * _feedback;
                interleaved[i + c] = x * (1 - _mix) + d * _mix;
            }
            _pos = (_pos + 1) % _frames;
        }
    }

    public override void Reset() => Array.Clear(_buffer);
}

internal sealed class RingModulatorEffect() : EffectBase(DspNodeTypes.RingModulator)
{
    private double _phase, _freq = 440;
    private float _mix = 0.5f;

    public override void SetParams(DspNode node)
    {
        _freq = node.Get("frequencyHz");
        _mix = (float)node.Get("mix");
    }

    public override void Process(Span<float> interleaved)
    {
        var inc = 2 * Math.PI * _freq / SampleRate;
        var ch = Channels;
        for (var i = 0; i + ch <= interleaved.Length; i += ch)
        {
            var m = (float)Math.Sin(_phase);
            for (var c = 0; c < ch; c++)
            {
                var x = interleaved[i + c];
                interleaved[i + c] = x * (1 - _mix) + x * m * _mix;
            }
            _phase += inc;
            if (_phase > 2 * Math.PI) _phase -= 2 * Math.PI;
        }
    }

    public override void Reset() => _phase = 0;
}

internal sealed class StereoWidthEffect() : EffectBase(DspNodeTypes.StereoWidth)
{
    private float _width = 1f;
    public override void SetParams(DspNode node) => _width = (float)Math.Clamp(node.Get("width"), 0, 2);

    public override void Process(Span<float> interleaved)
    {
        if (Channels < 2 || _width == 1f) return;
        var ch = Channels;
        for (var i = 0; i + ch <= interleaved.Length; i += ch)
        {
            var m = (interleaved[i] + interleaved[i + 1]) * 0.5f;
            var s = (interleaved[i] - interleaved[i + 1]) * 0.5f * _width;
            interleaved[i] = m + s;
            interleaved[i + 1] = m - s;
        }
    }
}

/// <summary>Freeverb (Jezar): 8 parallel lowpass-feedback combs and 4 series allpasses per channel.</summary>
internal sealed class ReverbEffect() : EffectBase(DspNodeTypes.Reverb)
{
    private static readonly int[] CombTuning = { 1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617 };
    private static readonly int[] AllpassTuning = { 556, 441, 341, 225 };
    private const int StereoSpread = 23;
    private const float FixedGain = 0.015f;

    private float[][][] _comb = Array.Empty<float[][]>();
    private int[][] _combPos = Array.Empty<int[]>();
    private float[][] _combStore = Array.Empty<float[]>();
    private float[][][] _allpass = Array.Empty<float[][]>();
    private int[][] _allpassPos = Array.Empty<int[]>();
    private float _feedback = 0.84f, _damp = 0.2f, _wet = 0.25f;

    public override void Configure(int sampleRate, int channels)
    {
        base.Configure(sampleRate, channels);
        var scale = sampleRate / 44100.0;
        _comb = new float[Channels][][];
        _combPos = new int[Channels][];
        _combStore = new float[Channels][];
        _allpass = new float[Channels][][];
        _allpassPos = new int[Channels][];
        for (var c = 0; c < Channels; c++)
        {
            var spread = (c % 2) * StereoSpread;
            _comb[c] = CombTuning.Select(t => new float[Math.Max(1, (int)((t + spread) * scale))]).ToArray();
            _combPos[c] = new int[CombTuning.Length];
            _combStore[c] = new float[CombTuning.Length];
            _allpass[c] = AllpassTuning.Select(t => new float[Math.Max(1, (int)((t + spread) * scale))]).ToArray();
            _allpassPos[c] = new int[AllpassTuning.Length];
        }
    }

    public override void SetParams(DspNode node)
    {
        _feedback = (float)(node.Get("roomSize") * 0.28 + 0.7);
        _damp = (float)(node.Get("damping") * 0.4);
        _wet = (float)Math.Clamp(node.Get("mix"), 0, 1);
    }

    public override void Process(Span<float> interleaved)
    {
        if (_comb.Length == 0) return;
        var ch = Channels;
        for (var i = 0; i + ch <= interleaved.Length; i += ch)
        {
            var mono = 0f;
            for (var c = 0; c < ch; c++) mono += interleaved[i + c];
            var input = mono / ch * FixedGain;
            for (var c = 0; c < ch; c++)
            {
                var acc = 0f;
                var combs = _comb[c];
                var pos = _combPos[c];
                var store = _combStore[c];
                for (var k = 0; k < combs.Length; k++)
                {
                    var buf = combs[k];
                    var y = buf[pos[k]];
                    store[k] = y * (1 - _damp) + store[k] * _damp;
                    buf[pos[k]] = input + store[k] * _feedback;
                    if (++pos[k] >= buf.Length) pos[k] = 0;
                    acc += y;
                }
                var aps = _allpass[c];
                var apos = _allpassPos[c];
                for (var k = 0; k < aps.Length; k++)
                {
                    var buf = aps[k];
                    var bufOut = buf[apos[k]];
                    var output = -acc + bufOut;
                    buf[apos[k]] = acc + bufOut * 0.5f;
                    if (++apos[k] >= buf.Length) apos[k] = 0;
                    acc = output;
                }
                var dry = interleaved[i + c];
                interleaved[i + c] = dry * (1 - _wet) + acc * _wet * 3f;
            }
        }
    }

    public override void Reset()
    {
        foreach (var c in _comb) foreach (var b in c) Array.Clear(b);
        foreach (var c in _allpass) foreach (var b in c) Array.Clear(b);
        foreach (var s in _combStore) Array.Clear(s);
    }
}

/// <summary>Chorus / flanger: LFO-modulated fractional delay with feedback; channels use phase-offset LFOs for width.</summary>
internal sealed class ModulatedDelayEffect(string type, double minMs, double maxMs, double defaultFeedback) : EffectBase(type)
{
    private float[] _buffer = Array.Empty<float>();
    private int _frames, _pos;
    private double _phase, _rate = 0.8, _depth = 0.5;
    private float _mix = 0.5f, _feedback = (float)defaultFeedback;
    private float[] _last = new float[2];

    public override void Configure(int sampleRate, int channels)
    {
        base.Configure(sampleRate, channels);
        _frames = (int)(sampleRate * (maxMs + 5) / 1000) + 4;
        _buffer = new float[_frames * Channels];
        _last = new float[Channels];
        _pos = 0;
    }

    public override void SetParams(DspNode node)
    {
        _rate = node.Get("rateHz");
        _depth = Math.Clamp(node.Get("depth"), 0, 1);
        _mix = (float)Math.Clamp(node.Get("mix"), 0, 1);
        _feedback = (float)Math.Clamp(node.Get("feedback"), 0, 0.95);
    }

    public override void Process(Span<float> interleaved)
    {
        if (_buffer.Length == 0) return;
        var ch = Channels;
        var inc = 2 * Math.PI * _rate / SampleRate;
        var center = (minMs + maxMs) / 2;
        var swing = (maxMs - minMs) / 2 * _depth;
        for (var i = 0; i + ch <= interleaved.Length; i += ch)
        {
            for (var c = 0; c < ch; c++)
            {
                var lfo = Math.Sin(_phase + c * Math.PI / 2);
                var delayFrames = (center + swing * lfo) * SampleRate / 1000;
                var readPos = _pos - delayFrames;
                while (readPos < 0) readPos += _frames;
                var i0 = (int)readPos;
                var frac = (float)(readPos - i0);
                var i1 = (i0 + 1) % _frames;
                var delayed = _buffer[i0 * ch + c] * (1 - frac) + _buffer[i1 * ch + c] * frac;
                var x = interleaved[i + c];
                _buffer[_pos * ch + c] = x + delayed * _feedback;
                interleaved[i + c] = x * (1 - _mix) + delayed * _mix;
            }
            _pos = (_pos + 1) % _frames;
            _phase += inc;
            if (_phase > 2 * Math.PI) _phase -= 2 * Math.PI;
        }
    }

    public override void Reset()
    {
        Array.Clear(_buffer);
        _phase = 0;
    }
}

/// <summary>Phaser: cascade of LFO-swept first-order allpass stages (200 Hz - 2 kHz) with feedback.</summary>
internal sealed class PhaserEffect() : EffectBase(DspNodeTypes.Phaser)
{
    private const int MaxStages = 12;
    private float[][] _state = Array.Empty<float[]>();
    private float[] _fb = new float[2];
    private double _phase, _rate = 0.5, _depth = 0.7;
    private int _stages = 6;
    private float _feedback = 0.3f, _mix = 0.5f;

    public override void Configure(int sampleRate, int channels)
    {
        base.Configure(sampleRate, channels);
        _state = Enumerable.Range(0, Channels).Select(_ => new float[MaxStages]).ToArray();
        _fb = new float[Channels];
    }

    public override void SetParams(DspNode node)
    {
        _rate = node.Get("rateHz");
        _depth = Math.Clamp(node.Get("depth"), 0, 1);
        _stages = Math.Clamp((int)Math.Round(node.Get("stages")), 2, MaxStages);
        _feedback = (float)Math.Clamp(node.Get("feedback"), 0, 0.95);
        _mix = (float)Math.Clamp(node.Get("mix"), 0, 1);
    }

    public override void Process(Span<float> interleaved)
    {
        if (_state.Length == 0) return;
        var ch = Channels;
        var inc = 2 * Math.PI * _rate / SampleRate;
        const double minHz = 200, maxHz = 2000;
        for (var i = 0; i + ch <= interleaved.Length; i += ch)
        {
            var lfo = 0.5 + 0.5 * Math.Sin(_phase);
            var hz = minHz * Math.Pow(maxHz / minHz, lfo * _depth);
            var t = Math.Tan(Math.PI * hz / SampleRate);
            var a = (float)((t - 1) / (t + 1));
            for (var c = 0; c < ch; c++)
            {
                var x = interleaved[i + c];
                var y = x + _fb[c] * _feedback;
                var st = _state[c];
                for (var s = 0; s < _stages; s++)
                {
                    var o = a * y + st[s];
                    st[s] = y - a * o;
                    y = o;
                }
                _fb[c] = y;
                interleaved[i + c] = x * (1 - _mix) + y * _mix;
            }
            _phase += inc;
            if (_phase > 2 * Math.PI) _phase -= 2 * Math.PI;
        }
    }

    public override void Reset()
    {
        foreach (var s in _state) Array.Clear(s);
        Array.Clear(_fb);
    }
}

/// <summary>Auto-wah: envelope follower driving a state-variable band-pass filter between min and max frequency.</summary>
internal sealed class AutoWahEffect() : EffectBase(DspNodeTypes.AutoWah)
{
    private float[] _low = new float[2], _band = new float[2];
    private float _env;
    private double _sensitivity = 0.5, _minHz = 300, _maxHz = 3000, _q = 2.5;
    private float _mix = 0.8f, _attack, _release;

    public override void Configure(int sampleRate, int channels)
    {
        base.Configure(sampleRate, channels);
        _low = new float[Channels];
        _band = new float[Channels];
        _attack = 1f - MathF.Exp(-1f / (sampleRate * 0.005f));
        _release = 1f - MathF.Exp(-1f / (sampleRate * 0.12f));
    }

    public override void SetParams(DspNode node)
    {
        _sensitivity = Math.Clamp(node.Get("sensitivity"), 0, 1);
        _minHz = node.Get("minHz");
        _maxHz = Math.Max(_minHz + 10, node.Get("maxHz"));
        _q = Math.Max(0.5, node.Get("q"));
        _mix = (float)Math.Clamp(node.Get("mix"), 0, 1);
    }

    public override void Process(Span<float> interleaved)
    {
        var ch = Channels;
        var damping = (float)(1 / _q);
        for (var i = 0; i + ch <= interleaved.Length; i += ch)
        {
            var level = 0f;
            for (var c = 0; c < ch; c++) level = Math.Max(level, MathF.Abs(interleaved[i + c]));
            _env += (level - _env) * (level > _env ? _attack : _release);
            var amount = Math.Clamp(_env * (0.5 + _sensitivity * 9.5), 0, 1);
            var hz = _minHz * Math.Pow(_maxHz / _minHz, amount);
            var f = (float)(2 * Math.Sin(Math.PI * Math.Min(hz, SampleRate / 6.0) / SampleRate));
            for (var c = 0; c < ch; c++)
            {
                var x = interleaved[i + c];
                var high = x - _low[c] - damping * _band[c];
                _band[c] += f * high;
                _low[c] += f * _band[c];
                interleaved[i + c] = x * (1 - _mix) + _band[c] * _mix;
            }
        }
    }

    public override void Reset()
    {
        Array.Clear(_low);
        Array.Clear(_band);
        _env = 0;
    }
}

internal sealed class DistortionEffect() : EffectBase(DspNodeTypes.Distortion)
{
    private float _pre = 10f, _mix = 0.7f, _toneCoef = 0.5f, _norm = 1f;
    private float[] _lp = new float[2];

    public override void Configure(int sampleRate, int channels)
    {
        base.Configure(sampleRate, channels);
        _lp = new float[Channels];
    }

    public override void SetParams(DspNode node)
    {
        var drive = Math.Clamp(node.Get("drive"), 0, 1);
        _pre = (float)(1 + drive * 49);
        _norm = 1f / MathF.Atan(_pre);
        var cutoff = 800 * Math.Pow(15, Math.Clamp(node.Get("tone"), 0, 1)); // 800 Hz .. 12 kHz
        _toneCoef = (float)(1 - Math.Exp(-2 * Math.PI * cutoff / SampleRate));
        _mix = (float)Math.Clamp(node.Get("mix"), 0, 1);
    }

    public override void Process(Span<float> interleaved)
    {
        var ch = Channels;
        for (var i = 0; i + ch <= interleaved.Length; i += ch)
            for (var c = 0; c < ch; c++)
            {
                var x = interleaved[i + c];
                var shaped = MathF.Atan(x * _pre) * _norm;
                _lp[c] += (shaped - _lp[c]) * _toneCoef;
                interleaved[i + c] = x * (1 - _mix) + _lp[c] * _mix;
            }
    }

    public override void Reset() => Array.Clear(_lp);
}

/// <summary>Stereo-linked feed-forward compressor with peak detection, soft attack/release and makeup gain.</summary>
internal sealed class CompressorEffect() : EffectBase(DspNodeTypes.Compressor)
{
    private double _threshold = -18, _ratio = 4, _attackMs = 10, _releaseMs = 120, _makeup;
    private double _attackCoef, _releaseCoef, _envDb = -120;

    public override void Configure(int sampleRate, int channels)
    {
        base.Configure(sampleRate, channels);
        UpdateCoefs();
    }

    public override void SetParams(DspNode node)
    {
        _threshold = node.Get("thresholdDb");
        _ratio = Math.Max(1, node.Get("ratio"));
        _attackMs = Math.Max(0.1, node.Get("attackMs"));
        _releaseMs = Math.Max(1, node.Get("releaseMs"));
        _makeup = node.Get("makeupDb");
        UpdateCoefs();
    }

    private void UpdateCoefs()
    {
        _attackCoef = Math.Exp(-1 / (SampleRate * _attackMs / 1000));
        _releaseCoef = Math.Exp(-1 / (SampleRate * _releaseMs / 1000));
    }

    public override void Process(Span<float> interleaved)
    {
        var ch = Channels;
        for (var i = 0; i + ch <= interleaved.Length; i += ch)
        {
            var peak = 0f;
            for (var c = 0; c < ch; c++) peak = Math.Max(peak, MathF.Abs(interleaved[i + c]));
            var levelDb = 20 * Math.Log10(Math.Max(peak, 1e-9));
            var coef = levelDb > _envDb ? _attackCoef : _releaseCoef;
            _envDb = coef * _envDb + (1 - coef) * levelDb;
            var over = _envDb - _threshold;
            var reduction = over > 0 ? over * (1 - 1 / _ratio) : 0;
            var gain = (float)Math.Pow(10, (_makeup - reduction) / 20);
            for (var c = 0; c < ch; c++) interleaved[i + c] *= gain;
        }
    }

    public override void Reset() => _envDb = -120;
}

/// <summary>Headphone crossfeed: each ear receives a low-passed (700 Hz), slightly delayed copy of the opposite channel.</summary>
internal sealed class CrossfeedEffect() : EffectBase(DspNodeTypes.Crossfeed)
{
    private float _amount = 0.3f, _lpCoef;
    private float _lpL, _lpR;
    private float[] _delayL = Array.Empty<float>(), _delayR = Array.Empty<float>();
    private int _pos;

    public override void Configure(int sampleRate, int channels)
    {
        base.Configure(sampleRate, channels);
        _lpCoef = (float)(1 - Math.Exp(-2 * Math.PI * 700 / sampleRate));
        var d = Math.Max(1, (int)(sampleRate * 0.0003));
        _delayL = new float[d];
        _delayR = new float[d];
        _pos = 0;
    }

    public override void SetParams(DspNode node) => _amount = (float)Math.Clamp(node.Get("amount"), 0, 1);

    public override void Process(Span<float> interleaved)
    {
        if (Channels < 2 || _amount <= 0 || _delayL.Length == 0) return;
        var ch = Channels;
        var feed = _amount * 0.6f;
        var norm = 1f / (1f + feed * 0.5f);
        for (var i = 0; i + ch <= interleaved.Length; i += ch)
        {
            var l = interleaved[i];
            var r = interleaved[i + 1];
            _lpL += (l - _lpL) * _lpCoef;
            _lpR += (r - _lpR) * _lpCoef;
            var dl = _delayL[_pos];
            var dr = _delayR[_pos];
            _delayL[_pos] = _lpL;
            _delayR[_pos] = _lpR;
            _pos = (_pos + 1) % _delayL.Length;
            interleaved[i] = (l + dr * feed) * norm;
            interleaved[i + 1] = (r + dl * feed) * norm;
        }
    }

    public override void Reset()
    {
        _lpL = _lpR = 0;
        Array.Clear(_delayL);
        Array.Clear(_delayR);
    }
}
