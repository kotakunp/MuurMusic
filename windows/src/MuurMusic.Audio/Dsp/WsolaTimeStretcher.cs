namespace MuurMusic.Audio.Dsp;

/// <summary>
/// WSOLA (waveform-similarity overlap-add) time stretcher: changes playback speed (0.5x - 2x) without changing pitch.
/// Hann-windowed frames of ~40 ms are overlap-added at 50% with the analysis position refined by cross-correlation within
/// ±10 ms so consecutive frames stay phase-coherent. Streaming: input is pulled on demand.
/// </summary>
public sealed class WsolaTimeStretcher
{
    public const double MinSpeed = 0.5, MaxSpeed = 2.0;

    private readonly int _channels;
    private readonly int _frameSize;   // N
    private readonly int _hop;         // Hs = N / 2
    private readonly int _tolerance;   // search ±
    private readonly float[] _window;
    private float[] _input;            // interleaved
    private long _inputStart;          // absolute frame index of _input[0]
    private int _inputFrames;
    private bool _inputEnded;
    private double _nominal;           // absolute analysis position of the next frame
    private long _prevChosen = -1;
    private readonly float[] _ola;     // N frames interleaved
    private readonly float[] _outQueue;
    private int _outOffset, _outCount; // frames
    private readonly float[] _mono;

    public WsolaTimeStretcher(int sampleRate, int channels, double frameMs = 40, double toleranceMs = 10)
    {
        _channels = Math.Max(1, channels);
        _frameSize = Math.Max(64, (int)(sampleRate * frameMs / 1000) & ~1);
        _hop = _frameSize / 2;
        _tolerance = Math.Max(8, (int)(sampleRate * toleranceMs / 1000));
        _window = new float[_frameSize];
        for (var i = 0; i < _frameSize; i++) _window[i] = (float)(0.5 - 0.5 * Math.Cos(2 * Math.PI * i / _frameSize));
        _input = new float[(_frameSize * 4 + _tolerance * 4) * _channels];
        _ola = new float[_frameSize * _channels];
        _outQueue = new float[_hop * _channels];
        _mono = new float[_frameSize + 2 * _tolerance + _frameSize];
        Speed = 1;
    }

    public double Speed { get; set; }
    public int Channels => _channels;
    /// <summary>True when the input reached its end and all output has been delivered.</summary>
    public bool Finished => _inputEnded && _outCount == 0 && _nominal >= _inputStart + _inputFrames;
    /// <summary>Frames of input buffered but not yet reflected in the output (latency).</summary>
    public int BufferedInputFrames => (int)Math.Max(0, _inputStart + _inputFrames - (long)_nominal);

    public void Reset()
    {
        _inputStart = 0;
        _inputFrames = 0;
        _inputEnded = false;
        _nominal = 0;
        _prevChosen = -1;
        _outOffset = _outCount = 0;
        Array.Clear(_ola);
    }

    /// <summary>
    /// Produces up to <paramref name="output"/>.Length / channels frames. <paramref name="pull"/> fills a buffer with input frames
    /// and returns how many it wrote (0 = end of input). Returns the number of frames written.
    /// </summary>
    public int Process(Span<float> output, PullDelegate pull)
    {
        var ch = _channels;
        var want = output.Length / ch;
        var written = 0;
        while (written < want)
        {
            if (_outCount > 0)
            {
                var n = Math.Min(_outCount, want - written);
                _outQueue.AsSpan(_outOffset * ch, n * ch).CopyTo(output.Slice(written * ch));
                _outOffset += n;
                _outCount -= n;
                written += n;
                continue;
            }
            if (!ProduceHop(pull)) break;
        }
        return written;
    }

    public delegate int PullDelegate(Span<float> buffer);

    private bool ProduceHop(PullDelegate pull)
    {
        var ch = _channels;
        var speed = Math.Clamp(Speed, MinSpeed, MaxSpeed);
        var ha = _hop * speed;
        var nominal = (long)Math.Round(_nominal);
        var natural = _prevChosen < 0 ? nominal : _prevChosen + _hop;
        var needEnd = Math.Max(nominal + _tolerance + _frameSize, natural + _frameSize);
        if (!EnsureInput(needEnd, pull) && nominal >= _inputStart + _inputFrames) return false;

        long chosen;
        if (_prevChosen < 0) chosen = nominal;
        else
        {
            var lo = Math.Max(_inputStart, nominal - _tolerance);
            var hi = nominal + _tolerance;
            chosen = BestOffset(natural, lo, hi);
        }

        // Overlap-add the windowed frame.
        for (var i = 0; i < _frameSize; i++)
        {
            var src = chosen + i - _inputStart;
            var w = _window[i];
            for (var c = 0; c < ch; c++)
            {
                var v = src >= 0 && src < _inputFrames ? _input[src * ch + c] : 0f;
                _ola[i * ch + c] += v * w;
            }
        }
        Array.Copy(_ola, 0, _outQueue, 0, _hop * ch);
        Array.Copy(_ola, _hop * ch, _ola, 0, (_frameSize - _hop) * ch);
        Array.Clear(_ola, (_frameSize - _hop) * ch, _hop * ch);
        _outOffset = 0;
        _outCount = _hop;

        _prevChosen = chosen;
        _nominal += ha;
        Discard(Math.Min((long)_nominal - _tolerance, _prevChosen + _hop) - 4);
        return true;
    }

    private long BestOffset(long natural, long lo, long hi)
    {
        var ch = _channels;
        var len = _hop;
        var maxStart = _inputStart + _inputFrames - len;
        hi = Math.Min(hi, maxStart);
        if (hi < lo) return Math.Max(lo, Math.Min(natural, maxStart));
        // Mono reference = natural continuation of the previous frame.
        var refSpan = _mono.AsSpan(0, len);
        for (var i = 0; i < len; i++)
        {
            var src = natural + i - _inputStart;
            float s = 0;
            if (src >= 0 && src < _inputFrames)
                for (var c = 0; c < ch; c++) s += _input[src * ch + c];
            refSpan[i] = s;
        }
        var best = lo;
        var bestScore = double.NegativeInfinity;
        const int step = 2;
        for (var cand = lo; cand <= hi; cand += step)
        {
            double dot = 0, energy = 1e-9;
            var off = (cand - _inputStart) * ch;
            for (var i = 0; i < len; i += 2)
            {
                float s = 0;
                var idx = off + i * ch;
                for (var c = 0; c < ch; c++) s += _input[idx + c];
                dot += s * refSpan[i];
                energy += s * s;
            }
            var score = dot / Math.Sqrt(energy);
            if (score > bestScore) { bestScore = score; best = cand; }
        }
        return best;
    }

    private bool EnsureInput(long endFrame, PullDelegate pull)
    {
        var ch = _channels;
        while (_inputStart + _inputFrames < endFrame && !_inputEnded)
        {
            var needed = (int)(endFrame - (_inputStart + _inputFrames));
            if ((_inputFrames + needed) * ch > _input.Length)
                Array.Resize(ref _input, Math.Max(_input.Length * 2, (_inputFrames + needed) * ch));
            var got = pull(_input.AsSpan(_inputFrames * ch, needed * ch));
            if (got <= 0) { _inputEnded = true; break; }
            _inputFrames += got;
        }
        return _inputStart + _inputFrames >= endFrame;
    }

    private void Discard(long beforeFrame)
    {
        var drop = (int)Math.Clamp(beforeFrame - _inputStart, 0, _inputFrames);
        if (drop <= 0) return;
        var ch = _channels;
        Array.Copy(_input, drop * ch, _input, 0, (_inputFrames - drop) * ch);
        _inputFrames -= drop;
        _inputStart += drop;
    }
}
