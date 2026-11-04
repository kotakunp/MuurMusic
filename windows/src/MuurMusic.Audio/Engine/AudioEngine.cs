using MuurMusic.Audio.Dsp;

namespace MuurMusic.Audio.Engine;

public enum EngineState { Stopped, Playing, Pausing, Paused }

/// <summary>How a track became current.</summary>
public enum TrackTransition
{
    /// <summary>Started explicitly with <see cref="AudioEngine.Play"/>.</summary>
    Manual,
    /// <summary>Followed the previous track sample-accurately (or after the configured gap when gapless is off).</summary>
    Gapless,
    /// <summary>Faded in over the end of the previous track.</summary>
    Crossfade
}

public sealed class EngineTrackEventArgs(TrackSource source, TrackTransition transition) : EventArgs
{
    public TrackSource Source { get; } = source;
    public TrackTransition Transition { get; } = transition;
}

public sealed class EngineTrackFinishedEventArgs(TrackSource source, bool completed, long playedFrames, string? error) : EventArgs
{
    public TrackSource Source { get; } = source;
    /// <summary>True when the track played to its end (false when replaced, stopped or failed).</summary>
    public bool Completed { get; } = completed;
    /// <summary>Frames consumed from the source at the time it finished (position in source frames).</summary>
    public long PlayedFrames { get; } = playedFrames;
    public string? Error { get; } = error;
}

/// <summary>
/// The mixer. Pulls interleaved float frames from the current <see cref="TrackSource"/> (and the outgoing one while crossfading),
/// applies per-track ReplayGain, gapless/crossfade transitions, WSOLA speed change, de-click envelopes for pause/seek, the
/// <see cref="DspProcessor"/>, volume (cubic taper) and feeds the meter and spectrum analyzer.
/// <see cref="Render"/> is called by the output on its real-time thread; every other member may be called from any thread.
/// Events are raised in order on a dedicated engine event thread (never on the render thread).
/// </summary>
public sealed class AudioEngine : IDisposable
{
    private readonly object _gate = new();
    private readonly EventPump _pump;
    private readonly WsolaTimeStretcher.PullDelegate _pull;
    private TrackSource? _current, _next, _fading;
    private bool _nextAllowCrossfade = true;
    private long _xfadePos, _xfadeTotal;
    private bool _fadingInterrupted;
    private long _gapRemaining;
    private bool _nextRequested;
    private bool _buffering;
    private volatile EngineState _state = EngineState.Stopped;
    private float _env = 1f, _envTarget = 1f;
    private TimeSpan? _pendingSeek;
    private float _appliedVolume = -1f;
    private float[] _tmp = new float[4096];
    private WsolaTimeStretcher _stretcher;
    private bool _stretchActive;
    private bool _disposed;

    public AudioEngine()
    {
        _pump = new EventPump("MuurMusic engine events", ex => Error?.Invoke(this, ex));
        _pull = ReadSources;
        SampleRate = 48000;
        Channels = 2;
        _stretcher = new WsolaTimeStretcher(SampleRate, Channels);
        Spectrum.SampleRate = SampleRate;
        Dsp.Configure(SampleRate, Channels);
    }

    public int SampleRate { get; private set; }
    public int Channels { get; private set; }
    public DspProcessor Dsp { get; } = new();
    public AudioMeter Meter { get; } = new();
    public SpectrumAnalyzer Spectrum { get; } = new();
    public EngineState State => _state;
    public bool IsBuffering => _buffering;

    /// <summary>Slider value 0..1; the engine applies a cubic taper (0.5 ≈ -18 dB).</summary>
    public double Volume { get; set; } = 1;
    public bool Muted { get; set; }
    /// <summary>Extra linear gain multiplier used for sleep-timer fades (0..1).</summary>
    public float FadeGain { get; set; } = 1f;
    /// <summary>Playback speed 0.5..2 (pitch preserved by WSOLA).</summary>
    public double Speed { get; set; } = 1;
    public bool Gapless { get; set; } = true;
    /// <summary>Silence inserted between tracks when <see cref="Gapless"/> is off.</summary>
    public int GapMilliseconds { get; set; } = 250;
    /// <summary>0 (off) to 12 seconds.</summary>
    public double CrossfadeSeconds { get; set; }
    /// <summary>Length of the fade applied on pause/resume/seek/manual track changes (0 disables).</summary>
    public double DeclickMilliseconds { get; set; } = 8;
    /// <summary>How long before the end of the current track <see cref="NextTrackNeeded"/> is raised (crossfade length is added).</summary>
    public double NextTrackLeadSeconds { get; set; } = 20;

    public TrackSource? Current => _current;
    public TrackSource? Next => _next;
    public TimeSpan Position => _current?.Position ?? TimeSpan.Zero;
    public TimeSpan Duration => _current?.Duration ?? TimeSpan.Zero;

    /// <summary>A track became current (manual start, gapless follow-up or crossfade).</summary>
    public event EventHandler<EngineTrackEventArgs>? TrackStarted;
    /// <summary>A track stopped being audible (played to the end, replaced, stopped or failed). Raised before it is disposed.</summary>
    public event EventHandler<EngineTrackFinishedEventArgs>? TrackFinished;
    /// <summary>The current track is close to its end and no next track is set: call <see cref="SetNext"/>.</summary>
    public event EventHandler<TrackSource>? NextTrackNeeded;
    /// <summary>The last track finished and there was no next track.</summary>
    public event EventHandler? Ended;
    public event EventHandler<bool>? BufferingChanged;
    /// <summary>The pause fade-out completed; the output can be paused now.</summary>
    public event EventHandler? PausedCompletely;
    public event EventHandler<Exception>? Error;

    private int DeclickFrames => (int)Math.Max(0, DeclickMilliseconds * SampleRate / 1000);
    private long CrossfadeFrames => (long)(Math.Clamp(CrossfadeSeconds, 0, 12) * SampleRate);

    /// <summary>Sets the output format. Stop playback first; sources must be created with the same format.</summary>
    public void Configure(int sampleRate, int channels)
    {
        lock (_gate)
        {
            SampleRate = sampleRate;
            Channels = channels;
            Dsp.Configure(sampleRate, channels);
            Spectrum.SampleRate = sampleRate;
            _stretcher = new WsolaTimeStretcher(sampleRate, channels);
            _stretchActive = false;
        }
    }

    /// <summary>Makes <paramref name="source"/> the current track. The previous one is faded out briefly to avoid a click.</summary>
    public void Play(TrackSource source, bool startPaused = false)
    {
        ArgumentNullException.ThrowIfNull(source);
        if (source.SampleRate != SampleRate || source.Channels != Channels)
            throw new InvalidOperationException($"Source format {source.SampleRate}/{source.Channels} does not match the engine format {SampleRate}/{Channels}.");
        source.Start();
        TrackSource? oldNext, finishedNow = null, fadingDrop = null;
        lock (_gate)
        {
            var old = _current;
            oldNext = _next;
            _next = null;
            _current = source;
            _pendingSeek = null;
            _gapRemaining = 0;
            _nextRequested = false;
            _stretcher.Reset();
            var declick = DeclickFrames;
            if (old is not null && _state == EngineState.Playing && declick > 0)
            {
                fadingDrop = _fading;
                _fading = old;
                _fadingInterrupted = true;
                _xfadePos = 0;
                _xfadeTotal = declick * 2;
                source.CrossfadeTotal = _xfadeTotal;
            }
            else
            {
                finishedNow = old;
                if (_fading is not null) { fadingDrop = _fading; _fading = null; }
            }
            if (startPaused)
            {
                _state = EngineState.Paused;
                _env = 0f;
                _envTarget = 0f;
            }
            else
            {
                if (_state != EngineState.Playing) { _env = declick > 0 ? 0f : 1f; }
                _envTarget = 1f;
                _state = EngineState.Playing;
            }
        }
        if (fadingDrop is not null) Retire(fadingDrop, completed: false);
        if (finishedNow is not null) Retire(finishedNow, completed: false);
        if (oldNext is not null) _pump.Post(oldNext.Dispose);
        _pump.Post(() => TrackStarted?.Invoke(this, new EngineTrackEventArgs(source, TrackTransition.Manual)));
    }

    /// <summary>Queues the track that follows the current one (null clears). It starts decoding immediately.</summary>
    public void SetNext(TrackSource? next, bool allowCrossfade = true)
    {
        if (next is not null)
        {
            if (next.SampleRate != SampleRate || next.Channels != Channels)
                throw new InvalidOperationException("Next source format does not match the engine format.");
            next.Start();
        }
        TrackSource? old;
        lock (_gate)
        {
            old = _next;
            _next = next;
            _nextAllowCrossfade = allowCrossfade;
            if (next is null) _nextRequested = false;
        }
        if (old is not null && !ReferenceEquals(old, next)) _pump.Post(old.Dispose);
    }

    public void Pause()
    {
        var immediate = false;
        lock (_gate)
        {
            if (_state != EngineState.Playing) return;
            if (DeclickFrames == 0) { _state = EngineState.Paused; immediate = true; }
            else { _state = EngineState.Pausing; _envTarget = 0f; }
        }
        if (immediate) _pump.Post(() => PausedCompletely?.Invoke(this, EventArgs.Empty));
    }

    public void Resume()
    {
        lock (_gate)
        {
            if (_state is not (EngineState.Paused or EngineState.Pausing) || _current is null) return;
            if (_state == EngineState.Paused) _env = DeclickFrames > 0 ? 0f : 1f;
            _state = EngineState.Playing;
            _envTarget = 1f;
        }
    }

    /// <summary>Seeks the current track. While playing, the jump happens after a short fade-out.</summary>
    public void Seek(TimeSpan position)
    {
        TrackSource? drop = null;
        lock (_gate)
        {
            if (_current is null) return;
            if (_state == EngineState.Playing && DeclickFrames > 0)
            {
                _pendingSeek = position;
                _envTarget = 0f;
                return;
            }
            drop = DoSeek(position);
        }
        if (drop is not null) Retire(drop, completed: false);
    }

    /// <summary>Stops playback and releases all sources.</summary>
    public void Stop()
    {
        TrackSource? cur, next, fading;
        lock (_gate)
        {
            cur = _current;
            next = _next;
            fading = _fading;
            _current = _next = _fading = null;
            _pendingSeek = null;
            _gapRemaining = 0;
            _nextRequested = false;
            _state = EngineState.Stopped;
            _stretcher.Reset();
            _env = _envTarget = 1f;
        }
        SetBuffering(false);
        if (fading is not null) Retire(fading, completed: false);
        if (cur is not null) Retire(cur, completed: false);
        if (next is not null) _pump.Post(next.Dispose);
        Spectrum.Clear();
        Meter.Reset();
        Dsp.Reset();
    }

    /// <summary>Renders one block of interleaved output frames (output thread).</summary>
    public void Render(Span<float> output)
    {
        try
        {
            lock (_gate) RenderLocked(output);
        }
        catch (Exception ex)
        {
            output.Clear();
            _pump.Post(() => Error?.Invoke(this, ex));
        }
    }

    private void RenderLocked(Span<float> output)
    {
        var ch = Channels;
        if (_state is EngineState.Stopped or EngineState.Paused)
        {
            output.Clear();
            Meter.Process(output, ch);
            return;
        }
        var frames = output.Length / ch;
        var toRead = frames;
        var declick = DeclickFrames;
        if (_envTarget == 0f && declick > 0)
            toRead = Math.Min(frames, (int)Math.Ceiling(_env * declick) + 1);

        var speed = Math.Clamp(Speed, WsolaTimeStretcher.MinSpeed, WsolaTimeStretcher.MaxSpeed);
        var stretch = Math.Abs(speed - 1) > 1e-3;
        if (stretch != _stretchActive)
        {
            _stretcher.Reset();
            _stretchActive = stretch;
        }
        var target = output.Slice(0, toRead * ch);
        int produced;
        if (stretch)
        {
            _stretcher.Speed = speed;
            produced = _stretcher.Process(target, _pull);
            // The stretcher treats an empty pull as end of input; restart it so playback resumes after an underrun.
            if (produced < toRead) _stretcher.Reset();
        }
        else produced = ReadSources(target);
        if (produced < frames) output.Slice(produced * ch).Clear();

        ApplyEnvelope(output.Slice(0, produced * ch), ch, declick);
        Dsp.Process(output);
        Spectrum.Write(output, ch);
        ApplyVolume(output, ch);
        Meter.Process(output, ch);
        CheckNextNeeded();
    }

    private void ApplyEnvelope(Span<float> buf, int ch, int declick)
    {
        if (_env == 1f && _envTarget == 1f && _pendingSeek is null && _state != EngineState.Pausing) return;
        var step = declick > 0 ? 1f / declick : 1f;
        var frames = buf.Length / ch;
        for (var f = 0; f < frames; f++)
        {
            if (_env < _envTarget) _env = Math.Min(_envTarget, _env + step);
            else if (_env > _envTarget) _env = Math.Max(_envTarget, _env - step);
            if (_env != 1f)
                for (var c = 0; c < ch; c++) buf[f * ch + c] *= _env;
            if (_env <= 0f && _envTarget <= 0f)
            {
                buf.Slice((f + 1) * ch).Clear();
                break;
            }
        }
        if (_env <= 0f && _envTarget <= 0f) OnEnvelopeSilent();
    }

    private void OnEnvelopeSilent()
    {
        if (_pendingSeek is { } pos)
        {
            _pendingSeek = null;
            var drop = DoSeek(pos);
            if (drop is not null) Retire(drop, completed: false);
            if (_state == EngineState.Playing) _envTarget = 1f;
        }
        if (_state == EngineState.Pausing)
        {
            _state = EngineState.Paused;
            _pump.Post(() => PausedCompletely?.Invoke(this, EventArgs.Empty));
        }
    }

    /// <summary>Seeks the current source; returns an outgoing crossfade source that must be retired.</summary>
    private TrackSource? DoSeek(TimeSpan position)
    {
        var drop = _fading;
        _fading = null;
        _current?.Seek(position);
        _gapRemaining = 0;
        _stretcher.Reset();
        if (_next is null) _nextRequested = false;
        return drop;
    }

    private int ReadSources(Span<float> dst)
    {
        var ch = Channels;
        var want = dst.Length / ch;
        var written = 0;
        var buffering = false;
        var guard = 0;
        while (written < want && guard++ < 64)
        {
            if (_gapRemaining > 0)
            {
                var g = (int)Math.Min(_gapRemaining, want - written);
                dst.Slice(written * ch, g * ch).Clear();
                _gapRemaining -= g;
                written += g;
                continue;
            }
            if (_current is null) break;
            if (_fading is null && _next is not null) TryStartCrossfade(_current);
            var cur = _current;
            var limit = want - written;
            if (_fading is null && _next is not null && _nextAllowCrossfade)
            {
                var xf = EffectiveCrossfade(cur, _next);
                var rem = cur.RemainingFrames;
                if (xf > 0 && rem > xf) limit = (int)Math.Min(limit, rem - xf);
            }
            var span = dst.Slice(written * ch, limit * ch);
            var n = cur.Read(span);
            if (n > 0)
            {
                var block = span.Slice(0, n * ch);
                ApplySourceGain(cur, block);
                if (_fading is not null) MixFading(block, n);
                written += n;
            }
            if (n < limit)
            {
                if (cur.IsFinished)
                {
                    FinishCurrent(cur);
                    continue;
                }
                if (n == 0)
                {
                    buffering = cur.IsBuffering;
                    break;
                }
            }
        }
        SetBuffering(buffering);
        return written;
    }

    private long EffectiveCrossfade(TrackSource cur, TrackSource next)
    {
        var xf = CrossfadeFrames;
        if (xf <= 0) return 0;
        if (cur.TotalFrames > 0) xf = Math.Min(xf, cur.TotalFrames / 2);
        if (next.TotalFrames > 0) xf = Math.Min(xf, next.TotalFrames / 2);
        return xf;
    }

    private void TryStartCrossfade(TrackSource cur)
    {
        if (!_nextAllowCrossfade || _pendingSeek is not null || _next is null) return;
        var xf = EffectiveCrossfade(cur, _next);
        if (xf <= 0) return;
        var rem = cur.RemainingFrames;
        if (rem < 0 || rem > xf) return;
        if (rem < SampleRate / 20) return; // too little left to fade; a plain gapless transition follows
        var next = _next;
        _next = null;
        _fading = cur;
        _fadingInterrupted = false;
        _xfadePos = 0;
        _xfadeTotal = rem;
        next.CrossfadeTotal = rem;
        _current = next;
        _nextRequested = false;
        _pump.Post(() => TrackStarted?.Invoke(this, new EngineTrackEventArgs(next, TrackTransition.Crossfade)));
    }

    private void MixFading(Span<float> block, int n)
    {
        var f = _fading!;
        var ch = Channels;
        if (_tmp.Length < n * ch) _tmp = new float[n * ch];
        var tmp = _tmp.AsSpan(0, n * ch);
        var got = f.Read(tmp);
        if (got > 0) ApplySourceGain(f, tmp.Slice(0, got * ch));
        var total = (double)Math.Max(1, _xfadeTotal);
        for (var i = 0; i < n; i++)
        {
            var t = Math.Min(1.0, (_xfadePos + i) / total);
            var gIn = (float)Math.Sin(t * Math.PI / 2);
            var gOut = (float)Math.Cos(t * Math.PI / 2);
            var o = i * ch;
            if (i < got)
                for (var c = 0; c < ch; c++) block[o + c] = block[o + c] * gIn + tmp[o + c] * gOut;
            else
                for (var c = 0; c < ch; c++) block[o + c] *= gIn;
        }
        _xfadePos += n;
        if (_xfadePos >= _xfadeTotal || got < n)
        {
            _fading = null;
            if (_current is not null) _current.CrossfadeTotal = 0;
            Retire(f, completed: !_fadingInterrupted && (got == n || f.IsFinished));
        }
    }

    private static void ApplySourceGain(TrackSource src, Span<float> block)
    {
        var target = src.Gain;
        var from = src.RenderGain < 0 ? target : src.RenderGain;
        src.RenderGain = target;
        if (from == 1f && target == 1f) return;
        if (from == target)
        {
            for (var i = 0; i < block.Length; i++) block[i] *= target;
            return;
        }
        var stepPerSample = (target - from) / block.Length;
        var g = from;
        for (var i = 0; i < block.Length; i++)
        {
            g += stepPerSample;
            block[i] *= g;
        }
    }

    private void FinishCurrent(TrackSource cur)
    {
        if (_fading is { } f)
        {
            _fading = null;
            Retire(f, completed: !_fadingInterrupted);
        }
        var next = _next;
        _next = null;
        _current = next;
        _nextRequested = false;
        Retire(cur, completed: cur.Error is null);
        if (next is not null)
        {
            if (!Gapless) _gapRemaining = (long)GapMilliseconds * SampleRate / 1000;
            next.CrossfadeTotal = 0;
            _pump.Post(() => TrackStarted?.Invoke(this, new EngineTrackEventArgs(next, TrackTransition.Gapless)));
        }
        else
        {
            _state = EngineState.Stopped;
            _pump.Post(() => Ended?.Invoke(this, EventArgs.Empty));
        }
    }

    private void Retire(TrackSource source, bool completed)
    {
        var played = source.FramesConsumed;
        var error = source.Error;
        _pump.Post(() =>
        {
            try { TrackFinished?.Invoke(this, new EngineTrackFinishedEventArgs(source, completed, played, error)); }
            finally { source.Dispose(); }
        });
    }

    private void ApplyVolume(Span<float> output, int ch)
    {
        var v = Muted ? 0.0 : Math.Clamp(Volume, 0, 1);
        var target = (float)(v * v * v) * Math.Clamp(FadeGain, 0f, 1f);
        var from = _appliedVolume < 0 ? target : _appliedVolume;
        _appliedVolume = target;
        if (from == 1f && target == 1f) return;
        if (from == target)
        {
            for (var i = 0; i < output.Length; i++) output[i] *= target;
            return;
        }
        var frames = output.Length / ch;
        var step = (target - from) / Math.Max(1, frames);
        var g = from;
        for (var f = 0; f < frames; f++)
        {
            g += step;
            for (var c = 0; c < ch; c++) output[f * ch + c] *= g;
        }
    }

    private void CheckNextNeeded()
    {
        if (_nextRequested || _next is not null || _current is null) return;
        var cur = _current;
        var lead = (long)((NextTrackLeadSeconds + Math.Clamp(CrossfadeSeconds, 0, 12)) * SampleRate);
        var rem = cur.RemainingFrames;
        if (cur.DecoderFinished || (rem >= 0 && rem <= lead))
        {
            _nextRequested = true;
            _pump.Post(() => NextTrackNeeded?.Invoke(this, cur));
        }
    }

    private void SetBuffering(bool value)
    {
        if (_buffering == value) return;
        _buffering = value;
        _pump.Post(() => BufferingChanged?.Invoke(this, value));
    }

    /// <summary>The volume slider value to linear gain mapping used by the engine.</summary>
    public static double VolumeToGain(double volume)
    {
        var v = Math.Clamp(volume, 0, 1);
        return v * v * v;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        Stop();
        _pump.Dispose();
    }
}
