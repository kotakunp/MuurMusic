namespace MuurMusic.Audio.Dsp;

/// <summary>
/// Look-ahead brick-wall limiter. A sliding-window minimum of the required gain is box-filtered over the look-ahead window,
/// so the gain has fully settled when a peak reaches the (delayed) output and no sample exceeds the ceiling.
/// </summary>
public sealed class LookaheadLimiter
{
    private int _channels = 2;
    private int _lookahead;
    private float[] _delay = Array.Empty<float>();
    private int _delayPos;
    private float[] _required = Array.Empty<float>();
    private long[] _dequeIdx = Array.Empty<long>();
    private float[] _dequeVal = Array.Empty<float>();
    private int _dqHead, _dqTail;
    private long _n;
    private float[] _box = Array.Empty<float>();
    private int _boxPos;
    private double _boxSum;
    private float _env = 1f;
    private float _releaseCoef;
    private int _sampleRate = 48000;

    public float CeilingDb { get; set; } = -0.3f;
    public float LookaheadMs { get; set; } = 5f;
    public float ReleaseMs { get; set; } = 80f;
    /// <summary>Linear gain applied before limiting (loudness boost).</summary>
    public float InputGain { get; set; } = 1f;
    /// <summary>Current gain reduction in dB (≤ 0), for metering.</summary>
    public float GainReductionDb => 20f * MathF.Log10(Math.Max(_env, 1e-6f));
    public int LatencyFrames => _lookahead;

    public void Configure(int sampleRate, int channels)
    {
        _sampleRate = sampleRate;
        _channels = Math.Max(1, channels);
        _lookahead = Math.Max(1, (int)(sampleRate * LookaheadMs / 1000));
        _delay = new float[_lookahead * _channels];
        _box = new float[_lookahead];
        _dequeIdx = new long[_lookahead + 2];
        _dequeVal = new float[_lookahead + 2];
        _releaseCoef = 1f - MathF.Exp(-1f / (sampleRate * ReleaseMs / 1000f));
        Reset();
    }

    public void Reset()
    {
        Array.Clear(_delay);
        _delayPos = 0;
        Array.Fill(_box, 1f);
        _boxSum = _lookahead;
        _boxPos = 0;
        _dqHead = _dqTail = 0;
        _n = 0;
        _env = 1f;
    }

    public void Process(Span<float> interleaved)
    {
        if (_delay.Length == 0) Configure(_sampleRate, _channels);
        var ch = _channels;
        var ceiling = MathF.Pow(10, CeilingDb / 20);
        var gainIn = InputGain;
        var cap = _lookahead + 2;
        for (var i = 0; i + ch <= interleaved.Length; i += ch)
        {
            var peak = 0f;
            for (var c = 0; c < ch; c++)
            {
                var v = interleaved[i + c] * gainIn;
                interleaved[i + c] = v;
                var a = MathF.Abs(v);
                if (a > peak) peak = a;
            }
            var required = peak > ceiling ? ceiling / peak : 1f;

            // Sliding minimum over the last _lookahead required gains (monotonic deque).
            while (_dqTail != _dqHead && _dequeVal[(_dqTail - 1 + cap) % cap] >= required) _dqTail = (_dqTail - 1 + cap) % cap;
            _dequeVal[_dqTail] = required;
            _dequeIdx[_dqTail] = _n;
            _dqTail = (_dqTail + 1) % cap;
            var oldest = _n - _lookahead + 1;
            while (_dequeIdx[_dqHead] < oldest) _dqHead = (_dqHead + 1) % cap;
            var windowMin = _dequeVal[_dqHead];
            _n++;

            // Instant attack, exponential release.
            _env = windowMin < _env ? windowMin : _env + (windowMin - _env) * _releaseCoef;

            // Box filter so the gain ramps smoothly into the peak.
            _boxSum += _env - _box[_boxPos];
            _box[_boxPos] = _env;
            _boxPos = (_boxPos + 1) % _lookahead;
            var gain = (float)(_boxSum / _lookahead);

            var d = _delayPos * ch;
            for (var c = 0; c < ch; c++)
            {
                var delayed = _delay[d + c];
                _delay[d + c] = interleaved[i + c];
                var y = delayed * gain;
                interleaved[i + c] = Math.Clamp(y, -ceiling, ceiling);
            }
            _delayPos = (_delayPos + 1) % _lookahead;
        }
    }
}
