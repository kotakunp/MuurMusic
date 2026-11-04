using MuurMusic.Audio.Decoding;
using MuurMusic.Core.Models;

namespace MuurMusic.Audio.Engine;

/// <summary>
/// A track prepared for playback: owns its decoder, a background decode thread and a ring buffer of output-format frames.
/// Handles CUE start/end offsets, seeking (any thread) and reports buffering/finished state to the render thread.
/// </summary>
public sealed class TrackSource : IDisposable
{
    private readonly object _lock = new();
    private readonly float[] _ring;
    private readonly int _capacityFrames;
    private long _readFrames;   // total frames read from the ring (since last seek reset)
    private long _writeFrames;  // total frames written into the ring
    private readonly long _startFrame;
    private readonly long _limitFrames;     // hard end (CUE), -1 when none
    private readonly long _estimatedFrames; // from duration metadata, -1 when unknown
    private long _decodedFrames;            // frames decoded relative to track start
    private long _consumed;
    private long _seekTarget = -1;
    private volatile bool _decoderFinished;
    private volatile bool _disposed;
    private Thread? _thread;
    private readonly bool _inline;
    private readonly float[] _scratch;
    private bool _started;

    public TrackSource(Track track, Guid entryId, IAudioDecoder decoder, int sampleRate, int channels, float gain = 1f,
        double bufferSeconds = 3, bool inlineDecoding = false)
    {
        Track = track;
        EntryId = entryId;
        Decoder = decoder;
        SampleRate = sampleRate;
        Channels = channels;
        Gain = gain;
        _inline = inlineDecoding;
        decoder.SetOutputFormat(sampleRate, channels);
        _capacityFrames = Math.Clamp((int)(sampleRate * Math.Max(0.5, bufferSeconds)), 8192, 8 * 1024 * 1024 / Math.Max(1, channels));
        _ring = new float[_capacityFrames * channels];
        _scratch = new float[4096 * channels];
        _startFrame = track.CueStartMs * sampleRate / 1000;
        _limitFrames = track.CueEndMs is { } end && end > track.CueStartMs ? (end - track.CueStartMs) * sampleRate / 1000 : -1;
        var durationMs = decoder.Info.Duration > TimeSpan.Zero ? (long)decoder.Info.Duration.TotalMilliseconds - track.CueStartMs : track.DurationMs;
        _estimatedFrames = _limitFrames >= 0 ? _limitFrames : durationMs > 0 ? durationMs * sampleRate / 1000 : -1;
    }

    public Track Track { get; }
    public Guid EntryId { get; }
    public IAudioDecoder Decoder { get; }
    public AudioStreamInfo Info => Decoder.Info;
    public int SampleRate { get; }
    public int Channels { get; }
    /// <summary>Linear gain (ReplayGain) applied by the mixer.</summary>
    public float Gain { get; set; }
    /// <summary>Set by the engine: the frame count over which this source was crossfaded in (0 = not crossfaded).</summary>
    internal long CrossfadeTotal { get; set; }
    /// <summary>Gain last applied by the mixer (render thread only; -1 until the first block).</summary>
    internal float RenderGain { get; set; } = -1f;
    /// <summary>Arbitrary tag for the owner (e.g. play statistics).</summary>
    public object? Tag { get; set; }

    public string? Error { get; private set; }
    public bool DecoderFinished => _decoderFinished;
    public long FramesConsumed => Interlocked.Read(ref _consumed);
    public TimeSpan Position => TimeSpan.FromSeconds((double)FramesConsumed / SampleRate);
    /// <summary>Track length in frames when known (CUE end or container duration), else -1.</summary>
    public long TotalFrames => _estimatedFrames;
    public TimeSpan Duration => _estimatedFrames >= 0 ? TimeSpan.FromSeconds((double)_estimatedFrames / SampleRate) : TimeSpan.FromMilliseconds(Track.DurationMs);

    public int BufferedFrames
    {
        get { lock (_lock) return (int)(_writeFrames - _readFrames); }
    }

    public bool IsSeeking => Interlocked.Read(ref _seekTarget) >= 0;
    /// <summary>True when the decoder is done and every decoded frame has been played.</summary>
    public bool IsFinished => _decoderFinished && !IsSeeking && BufferedFrames == 0;
    public bool IsBuffering => !IsFinished && (IsSeeking || BufferedFrames == 0);

    /// <summary>Frames left to play: exact once decoding finished, otherwise estimated from the length; -1 if unknown.</summary>
    public long RemainingFrames
    {
        get
        {
            if (_decoderFinished && !IsSeeking) return BufferedFrames;
            return _estimatedFrames >= 0 ? Math.Max(0, _estimatedFrames - FramesConsumed) : -1;
        }
    }

    public void Start()
    {
        if (_started) return;
        _started = true;
        if (_startFrame > 0) Interlocked.Exchange(ref _seekTarget, 0);
        if (_inline) return;
        _thread = new Thread(DecodeLoop) { IsBackground = true, Name = $"Decode {Track.DisplayTitle}", Priority = ThreadPriority.AboveNormal };
        _thread.Start();
    }

    /// <summary>Seeks within the track (relative to its CUE start). Safe from any thread.</summary>
    public void Seek(TimeSpan position)
    {
        var frames = Math.Max(0, (long)(position.TotalSeconds * SampleRate));
        if (_limitFrames >= 0) frames = Math.Min(frames, _limitFrames);
        lock (_lock)
        {
            Interlocked.Exchange(ref _seekTarget, frames);
            Interlocked.Exchange(ref _consumed, frames);
            Monitor.PulseAll(_lock);
        }
    }

    /// <summary>Render thread: copies up to dst.Length / Channels frames. Returns frames copied (0 when buffering or finished).</summary>
    public int Read(Span<float> dst)
    {
        if (_inline) FillInline(dst.Length / Channels);
        if (IsSeeking) return 0;
        var ch = Channels;
        int frames;
        lock (_lock)
        {
            var available = (int)(_writeFrames - _readFrames);
            frames = Math.Min(available, dst.Length / ch);
            if (frames == 0) return 0;
            var start = (int)(_readFrames % _capacityFrames);
            var first = Math.Min(frames, _capacityFrames - start);
            _ring.AsSpan(start * ch, first * ch).CopyTo(dst);
            if (first < frames) _ring.AsSpan(0, (frames - first) * ch).CopyTo(dst.Slice(first * ch));
            _readFrames += frames;
            Monitor.PulseAll(_lock);
        }
        Interlocked.Add(ref _consumed, frames);
        return frames;
    }

    private void FillInline(int framesWanted)
    {
        HandleSeek();
        while (!_decoderFinished && BufferedFrames < framesWanted)
            if (!DecodeChunk(blockUntilSpace: false)) break;
    }

    private void DecodeLoop()
    {
        try
        {
            while (!_disposed)
            {
                HandleSeek();
                if (_decoderFinished)
                {
                    lock (_lock)
                    {
                        if (_disposed) break;
                        if (Interlocked.Read(ref _seekTarget) < 0) Monitor.Wait(_lock, 250);
                    }
                    continue;
                }
                DecodeChunk(blockUntilSpace: true);
            }
        }
        catch (Exception ex) when (!_disposed)
        {
            Error ??= ex.Message;
            _decoderFinished = true;
        }
    }

    private void HandleSeek()
    {
        var target = Interlocked.Read(ref _seekTarget);
        if (target < 0) return;
        try
        {
            if (Decoder.CanSeek || target == 0 && _startFrame == 0) Decoder.Seek(TimeSpan.FromSeconds((double)(_startFrame + target) / SampleRate));
            Decoder.SetOutputFormat(SampleRate, Channels);
            _decoderFinished = false;
            Error = null;
        }
        catch (Exception ex)
        {
            Error = ex.Message;
            _decoderFinished = true;
        }
        lock (_lock)
        {
            _readFrames = _writeFrames = 0;
            _decodedFrames = target;
            // A newer seek may have arrived while the decoder was seeking; keep it pending.
            Interlocked.CompareExchange(ref _seekTarget, -1, target);
            Interlocked.Exchange(ref _consumed, target);
        }
    }

    /// <summary>Decodes one chunk into the ring. Returns false when the decoder finished.</summary>
    private bool DecodeChunk(bool blockUntilSpace)
    {
        var ch = Channels;
        var maxFrames = _scratch.Length / ch;
        if (_limitFrames >= 0) maxFrames = (int)Math.Min(maxFrames, Math.Max(0, _limitFrames - _decodedFrames));
        int n;
        if (maxFrames == 0) n = 0;
        else
        {
            try { n = Decoder.Read(_scratch.AsSpan(0, maxFrames * ch)); }
            catch (Exception ex)
            {
                Error = ex.Message;
                n = 0;
            }
        }
        if (n == 0)
        {
            Error ??= Decoder.Error;
            _decoderFinished = true;
            lock (_lock) Monitor.PulseAll(_lock);
            return false;
        }
        var offset = 0;
        while (offset < n)
        {
            lock (_lock)
            {
                if (_disposed || Interlocked.Read(ref _seekTarget) >= 0) return true; // a seek discards this chunk
                var space = _capacityFrames - (int)(_writeFrames - _readFrames);
                if (space == 0)
                {
                    if (!blockUntilSpace) return true;
                    Monitor.Wait(_lock, 100);
                    continue;
                }
                var count = Math.Min(space, n - offset);
                var start = (int)(_writeFrames % _capacityFrames);
                var first = Math.Min(count, _capacityFrames - start);
                _scratch.AsSpan(offset * ch, first * ch).CopyTo(_ring.AsSpan(start * ch));
                if (first < count) _scratch.AsSpan((offset + first) * ch, (count - first) * ch).CopyTo(_ring.AsSpan(0));
                _writeFrames += count;
                offset += count;
            }
        }
        _decodedFrames += n;
        return true;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        Decoder.Abort();
        lock (_lock) Monitor.PulseAll(_lock);
        if (_thread is not null && _thread != Thread.CurrentThread) _thread.Join(2000);
        Decoder.Dispose();
    }
}
