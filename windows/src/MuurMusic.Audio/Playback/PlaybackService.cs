using System.Threading.Channels;
using Microsoft.Extensions.Logging;
using MuurMusic.Audio.Casting;
using MuurMusic.Audio.Dsp;
using MuurMusic.Audio.Engine;
using MuurMusic.Audio.FFmpeg;
using MuurMusic.Audio.Output;
using MuurMusic.Audio.Smtc;
using MuurMusic.Core.Data;
using MuurMusic.Core.Downloads;
using MuurMusic.Core.Infrastructure;
using MuurMusic.Core.Models;
using MuurMusic.Core.Playback;
using MuurMusic.Core.Settings;
using MuurMusic.Core.Sources;
using MuurMusic.Core.Tags;

namespace MuurMusic.Audio.Playback;

/// <summary>Playback states surfaced to the UI and SMTC.</summary>
public enum PlayerState { Stopped, Playing, Paused, Buffering }

public sealed class PlaybackTrackEventArgs(Track track, Guid entryId) : EventArgs
{
    public Track Track { get; } = track;
    public Guid EntryId { get; } = entryId;
}

public sealed class PlaybackErrorEventArgs(string message, Track? track, Exception? exception) : EventArgs
{
    public string Message { get; } = message;
    public Track? Track { get; } = track;
    public Exception? Exception { get; } = exception;
}

/// <summary>
/// The playback facade the UI talks to: play queue, transport controls, seek, volume, sleep timer, bookmarks,
/// play statistics, queue persistence, WASAPI output management and casting. All members are thread-safe; work is
/// serialized on an internal worker. Events are raised through <see cref="IEventDispatcher"/> (UI thread once the app
/// sets a poster). Poll <see cref="Position"/> from a UI timer (e.g. 4-10 Hz).
/// </summary>
public interface IPlaybackService : IAsyncDisposable
{
    /// <summary>The play queue. Read freely; mutate only through this service's methods.</summary>
    PlayQueue Queue { get; }
    PlayerState State { get; }
    /// <summary>True while the engine waits for data (network underrun, seek, initial fill).</summary>
    bool IsBuffering { get; }
    Track? CurrentTrack { get; }
    Guid? CurrentEntryId { get; }
    TimeSpan Position { get; }
    TimeSpan Duration { get; }
    /// <summary>0..1 (cubic taper applied by the engine). Persisted.</summary>
    double Volume { get; set; }
    bool Muted { get; set; }
    /// <summary>0.5..2, pitch preserved. Persisted.</summary>
    double Speed { get; set; }
    bool Shuffle { get; set; }
    RepeatMode Repeat { get; set; }
    /// <summary>Stop when the current track ends (instead of advancing).</summary>
    bool StopAfterCurrent { get; set; }
    TimeSpan? SleepTimerRemaining { get; }
    bool IsCasting { get; }
    ICastManager Cast { get; }
    /// <summary>The mixer: DSP (equalizer, chain, loudness), meter and spectrum analyzer live here.</summary>
    AudioEngine Engine { get; }
    IAudioOutput Output { get; }
    SmtcService Smtc { get; }

    event EventHandler? StateChanged;
    event EventHandler? QueueChanged;
    event EventHandler<PlaybackTrackEventArgs>? TrackChanged;
    event EventHandler<PlaybackErrorEventArgs>? PlaybackError;
    /// <summary>Audio endpoints appeared/disappeared; re-read <see cref="GetOutputDevices"/>.</summary>
    event EventHandler? OutputDevicesChanged;

    /// <summary>Restores the persisted queue and binds SMTC to the main window. Call once after the window exists.</summary>
    Task InitializeAsync(IntPtr mainWindowHandle, CancellationToken ct = default);

    Task PlayAsync(IReadOnlyList<Track> tracks, int startIndex = 0, TimeSpan? startPosition = null, CancellationToken ct = default);
    Task PlayEntryAsync(Guid entryId, CancellationToken ct = default);
    Task PlayAtIndexAsync(int index, CancellationToken ct = default);
    void EnqueueNext(IEnumerable<Track> tracks);
    void EnqueueLast(IEnumerable<Track> tracks);
    Task RemoveFromQueueAsync(IEnumerable<Guid> entryIds);
    void MoveQueueEntry(int from, int to);
    Task ClearQueueAsync();

    Task TogglePlayPauseAsync();
    Task PlayAsync();
    Task PauseAsync();
    Task StopAsync();
    Task NextAsync();
    Task PreviousAsync();
    Task SeekAsync(TimeSpan position);
    Task SkipBackAsync();
    Task SkipForwardAsync();

    /// <summary>Pause playback after the given time (with a 10 s fade-out on local output). Null cancels.</summary>
    void SetSleepTimer(TimeSpan? duration);
    Task<Bookmark?> AddBookmarkAsync(string? note = null, CancellationToken ct = default);
    Task GoToBookmarkAsync(Bookmark bookmark, CancellationToken ct = default);

    Task ConnectCastAsync(CastDeviceInfo device, CancellationToken ct = default);
    Task DisconnectCastAsync(bool resumeLocally = true, CancellationToken ct = default);

    IReadOnlyList<OutputDeviceInfo> GetOutputDevices();
    /// <summary>Re-applies output settings (device, mode, rate, buffer). Called automatically when settings change.</summary>
    Task ReopenOutputAsync();
    /// <summary>Persists the queue and settings now (call on app suspend/exit).</summary>
    Task FlushAsync();
}

public sealed class PlaybackService : IPlaybackService
{
    private const long MinPlayedMsForPlayCount = 30_000;

    private sealed class SuppressMarker { public static readonly SuppressMarker Instance = new(); }

    private readonly ISettingsService _settings;
    private readonly ISourceManager _sources;
    private readonly ITrackRepository _tracks;
    private readonly IBookmarkRepository _bookmarks;
    private readonly IQueueStore _queueStore;
    private readonly IDownloadManager _downloads;
    private readonly IArtworkCache _artwork;
    private readonly IEventDispatcher _dispatcher;
    private readonly ILogger<PlaybackService> _log;
    private readonly Channel<Func<Task>> _work = Channel.CreateUnbounded<Func<Task>>();
    private readonly Task _worker;
    private readonly Timer _queueSaveTimer;
    private readonly Timer _positionSaveTimer;
    private Timer? _sleepTimer;
    private DateTimeOffset _sleepEnd;
    private int _state = (int)PlayerState.Stopped;
    private volatile bool _casting;
    private TrackSource? _currentSource;
    private QueueEntry? _pendingNext;
    private int _pendingNextSkips;
    private long _loadToken;
    private long? _pendingSkipTrackId;
    private bool _openingOutput;
    private TimeSpan? _restoredPosition;
    private int _stopAfterCurrent;
    private bool _disposed;

    public PlaybackService(
        ISettingsService settings, ISourceManager sources, ITrackRepository tracks, IBookmarkRepository bookmarks,
        IQueueStore queueStore, IDownloadManager downloads, IArtworkCache artwork, IEventDispatcher dispatcher,
        AudioEngine engine, IAudioOutput output, ICastManager cast, ILoggerFactory loggerFactory)
    {
        _settings = settings;
        _sources = sources;
        _tracks = tracks;
        _bookmarks = bookmarks;
        _queueStore = queueStore;
        _downloads = downloads;
        _artwork = artwork;
        _dispatcher = dispatcher;
        _log = loggerFactory.CreateLogger<PlaybackService>();
        Engine = engine;
        Output = output;
        Cast = cast;
        Smtc = new SmtcService(loggerFactory.CreateLogger<SmtcService>());
        Queue = new PlayQueue { Repeat = _settings.Current.Repeat };
        if (_settings.Current.Shuffle) Queue.SetShuffle(true);
        ApplySettingsToEngine(_settings.Current);

        engine.TrackStarted += (_, e) => Post(() => OnTrackStarted(e));
        engine.TrackFinished += (_, e) => Post(() => OnTrackFinished(e));
        engine.NextTrackNeeded += (_, cur) => Post(() => OnNextTrackNeeded(cur));
        engine.Ended += (_, _) => Post(OnEnded);
        engine.PausedCompletely += (_, _) => Post(() =>
        {
            Output.PausePlayback();
            return Task.CompletedTask;
        });
        engine.BufferingChanged += (_, buffering) => Post(() =>
        {
            RaiseStateChanged();
            Smtc.UpdatePlaybackStatus(State, buffering);
            return Task.CompletedTask;
        });
        engine.Error += (_, ex) => Post(() =>
        {
            RaiseError("Playback engine error: " + ex.Message, null, ex);
            return Task.CompletedTask;
        });
        output.PlaybackError += (_, ex) => Post(async () =>
        {
            _log.LogWarning(ex, "Audio output failed; reopening");
            try { await ReopenOutputLockedAsync(0, 0, default).ConfigureAwait(false); }
            catch (Exception rex)
            {
                SetState(PlayerState.Stopped);
                RaiseError("Audio output failed: " + rex.Message, CurrentTrack, rex);
            }
        });
        output.DefaultDeviceChanged += (_, _) => Post(async () =>
        {
            if (Output.DeviceId is null && Output.IsOpen)
            {
                _log.LogInformation("Default audio device changed; following");
                await ReopenOutputLockedAsync(_currentSource?.Info.SampleRate ?? 0, _currentSource?.Info.Channels ?? 0, default).ConfigureAwait(false);
            }
        });
        output.DeviceListChanged += (_, _) => Post(async () =>
        {
            _dispatcher.Post(() => OutputDevicesChanged?.Invoke(this, EventArgs.Empty));
            if (Output.DeviceId is { } id && Output.IsOpen && Output.GetDevices().All(d => d.Id != id))
            {
                _log.LogWarning("The selected audio device disappeared; falling back to the default device");
                await ReopenOutputLockedAsync(0, 0, default).ConfigureAwait(false);
            }
        });
        cast.SessionTrackEnded += (_, _) => Post(OnCastTrackEnded);
        cast.SessionStateChanged += (_, _) => Post(() =>
        {
            RaiseStateChanged();
            return Task.CompletedTask;
        });
        cast.SessionLost += (_, _) => Post(() =>
        {
            _casting = false;
            SetState(PlayerState.Stopped);
            RaiseError("The cast device disconnected.", CurrentTrack, null);
            return Task.CompletedTask;
        });
        settings.Changed += (_, e) => Post(() =>
        {
            OnSettingsChanged(e.Old, e.New);
            return Task.CompletedTask;
        });
        Queue.Changed += (_, _) =>
        {
            SaveQueueDebounced();
            _dispatcher.Post(() => QueueChanged?.Invoke(this, EventArgs.Empty));
        };
        WireSmtc();

        _worker = Task.Run(WorkerLoopAsync);
        _queueSaveTimer = new Timer(_ => Post(SaveQueueNowAsync), null, Timeout.Infinite, Timeout.Infinite);
        _positionSaveTimer = new Timer(_ => Post(() =>
        {
            if (State == PlayerState.Playing) return SaveQueueNowAsync();
            return Task.CompletedTask;
        }), null, TimeSpan.FromSeconds(15), TimeSpan.FromSeconds(15));
    }

    public PlayQueue Queue { get; }
    public AudioEngine Engine { get; }
    public IAudioOutput Output { get; }
    public ICastManager Cast { get; }
    public SmtcService Smtc { get; }

    public PlayerState State => (PlayerState)_state;
    public bool IsBuffering => !_casting && Engine.IsBuffering;
    public Track? CurrentTrack => _casting ? Queue.Current?.Track : _currentSource?.Track ?? Queue.Current?.Track;
    public Guid? CurrentEntryId => Queue.Current?.EntryId;
    public TimeSpan Position => _casting ? Cast.Position : Engine.Position;
    public TimeSpan Duration => CurrentTrack?.Duration ?? TimeSpan.Zero;
    public bool IsCasting => _casting;

    public bool StopAfterCurrent
    {
        get => _stopAfterCurrent != 0;
        set => Post(() =>
        {
            Interlocked.Exchange(ref _stopAfterCurrent, value ? 1 : 0);
            if (value && _pendingNext is not null)
            {
                _pendingNext = null;
                Engine.SetNext(null);
            }
            RaiseStateChanged();
            return Task.CompletedTask;
        });
    }

    public TimeSpan? SleepTimerRemaining => _sleepTimer is null ? null : _sleepEnd - DateTimeOffset.UtcNow;

    public double Volume
    {
        get => _settings.Current.Volume;
        set
        {
            var v = Math.Clamp(value, 0, 1);
            _settings.Update(s => s.Volume = v);
            Post(async () =>
            {
                Engine.Volume = v;
                if (_casting) await Cast.SetVolumeAsync(v).ConfigureAwait(false);
            });
        }
    }

    public bool Muted
    {
        get => _settings.Current.Muted;
        set
        {
            _settings.Update(s => s.Muted = value);
            Post(async () =>
            {
                Engine.Muted = value;
                if (_casting) await Cast.SetMutedAsync(value).ConfigureAwait(false);
            });
        }
    }

    public double Speed
    {
        get => _settings.Current.Speed;
        set
        {
            var v = Math.Clamp(value, WsolaTimeStretcher.MinSpeed, WsolaTimeStretcher.MaxSpeed);
            _settings.Update(s => s.Speed = v);
            Post(() =>
            {
                Engine.Speed = v;
                return Task.CompletedTask;
            });
        }
    }

    public bool Shuffle
    {
        get => Queue.Shuffle;
        set
        {
            _settings.Update(s => s.Shuffle = value);
            Post(() =>
            {
                Queue.SetShuffle(value);
                Smtc.UpdateModes(value, Queue.Repeat);
                return Task.CompletedTask;
            });
        }
    }

    public RepeatMode Repeat
    {
        get => Queue.Repeat;
        set
        {
            _settings.Update(s => s.Repeat = value);
            Post(() =>
            {
                Queue.Repeat = value;
                Smtc.UpdateModes(Queue.Shuffle, value);
                return Task.CompletedTask;
            });
        }
    }

    public event EventHandler? StateChanged;
    public event EventHandler? QueueChanged;
    public event EventHandler<PlaybackTrackEventArgs>? TrackChanged;
    public event EventHandler<PlaybackErrorEventArgs>? PlaybackError;
    public event EventHandler? OutputDevicesChanged;

    // ------------------------------------------------ lifecycle

    public async Task InitializeAsync(IntPtr mainWindowHandle, CancellationToken ct = default)
    {
        Smtc.Initialize(mainWindowHandle);
        var tcs = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        Post(async () =>
        {
            try
            {
                var s = _settings.Current;
                if (s.RememberQueue)
                {
                    var snapshot = await _queueStore.LoadAsync(ct).ConfigureAwait(false);
                    if (snapshot is not null)
                    {
                        _queueStore.Apply(Queue, snapshot);
                        _restoredPosition = snapshot.PositionMs > 0 ? TimeSpan.FromMilliseconds(snapshot.PositionMs) : null;
                    }
                }
                Smtc.UpdateModes(Queue.Shuffle, Queue.Repeat);
                tcs.TrySetResult();
            }
            catch (Exception ex) { tcs.TrySetException(ex); }
        });
        await tcs.Task.ConfigureAwait(false);
        if (_settings.Current.ResumePlaybackOnStartup && Queue.Current is not null)
            await PlayAsync().ConfigureAwait(false);
    }

    private void WireSmtc()
    {
        Smtc.Command += (_, cmd) => Post(() => cmd switch
        {
            SmtcCommand.Play => PlayLockedAsync(default),
            SmtcCommand.Pause => PauseLockedAsync(default),
            SmtcCommand.Stop => StopLockedAsync(),
            SmtcCommand.Next => NextLockedAsync(default),
            SmtcCommand.Previous => PreviousLockedAsync(default),
            _ => Task.CompletedTask
        });
        Smtc.SeekRequested += (_, pos) => Post(() => SeekLockedAsync(pos));
        Smtc.ShuffleChangeRequested += (_, on) => Shuffle = on;
        Smtc.RepeatChangeRequested += (_, mode) => Repeat = mode;
        Smtc.PlaybackRateChangeRequested += (_, rate) => Speed = rate;
    }

    // ------------------------------------------------ transport

    public Task PlayAsync(IReadOnlyList<Track> tracks, int startIndex = 0, TimeSpan? startPosition = null, CancellationToken ct = default) =>
        Enqueue(() =>
        {
            Queue.Set(tracks, startIndex);
            return PlayCurrentLockedAsync(startPosition, allowSkip: true, ct);
        });

    public Task PlayEntryAsync(Guid entryId, CancellationToken ct = default) =>
        Enqueue(() =>
        {
            var index = -1;
            for (var i = 0; i < Queue.Items.Count; i++)
                if (Queue.Items[i].EntryId == entryId) { index = i; break; }
            if (index < 0) return Task.CompletedTask;
            Queue.JumpTo(index);
            return PlayCurrentLockedAsync(null, allowSkip: true, ct);
        });

    public Task PlayAtIndexAsync(int index, CancellationToken ct = default) =>
        Enqueue(() =>
        {
            if (!Queue.JumpTo(index)) return Task.CompletedTask;
            return PlayCurrentLockedAsync(null, allowSkip: true, ct);
        });

    public void EnqueueNext(IEnumerable<Track> tracks) => Post(() =>
    {
        Queue.PlayNext(tracks);
        return Task.CompletedTask;
    });

    public void EnqueueLast(IEnumerable<Track> tracks) => Post(() =>
    {
        Queue.AddToEnd(tracks);
        return Task.CompletedTask;
    });

    public Task RemoveFromQueueAsync(IEnumerable<Guid> entryIds) => Enqueue(() =>
    {
        var set = entryIds.ToHashSet();
        var removedCurrent = Queue.Current is { } cur && set.Contains(cur.EntryId);
        Queue.RemoveEntries(set);
        if (removedCurrent)
        {
            if (Queue.Current is { } next && State != PlayerState.Stopped) return PlayCurrentLockedAsync(null, allowSkip: true, default);
            return StopLockedAsync();
        }
        return Task.CompletedTask;
    });

    public void MoveQueueEntry(int from, int to) => Post(() =>
    {
        Queue.Move(from, to);
        return Task.CompletedTask;
    });

    public Task ClearQueueAsync() => Enqueue(async () =>
    {
        await StopLockedAsync().ConfigureAwait(false);
        Queue.Clear();
    });

    public Task TogglePlayPauseAsync() => Enqueue(async () =>
    {
        switch (State)
        {
            case PlayerState.Playing:
            case PlayerState.Buffering:
                await PauseLockedAsync(default).ConfigureAwait(false);
                break;
            case PlayerState.Paused:
                await ResumeLockedAsync().ConfigureAwait(false);
                break;
            default:
                await PlayLockedAsync(default).ConfigureAwait(false);
                break;
        }
    });

    public Task PlayAsync() => Enqueue(() => PlayLockedAsync(default));
    public Task PauseAsync() => Enqueue(() => PauseLockedAsync(default));
    public Task StopAsync() => Enqueue(StopLockedAsync);
    public Task NextAsync() => Enqueue(() => NextLockedAsync(default));
    public Task PreviousAsync() => Enqueue(() => PreviousLockedAsync(default));

    public Task SeekAsync(TimeSpan position) => Enqueue(() => SeekLockedAsync(position));

    public Task SkipBackAsync() => Enqueue(() => SeekLockedAsync(Position - TimeSpan.FromSeconds(Math.Max(1, _settings.Current.SkipBackSeconds))));

    public Task SkipForwardAsync() => Enqueue(() => SeekLockedAsync(Position + TimeSpan.FromSeconds(Math.Max(1, _settings.Current.SkipForwardSeconds))));

    private async Task PlayLockedAsync(CancellationToken ct)
    {
        if (_casting)
        {
            await Cast.PlayAsync(ct).ConfigureAwait(false);
            SetState(PlayerState.Playing);
            return;
        }
        if (Engine.State is EngineState.Paused or EngineState.Pausing)
        {
            await ResumeLockedAsync().ConfigureAwait(false);
            return;
        }
        if (Queue.Current is not null)
            await PlayCurrentLockedAsync(_restoredPosition, allowSkip: true, ct).ConfigureAwait(false);
    }

    private async Task PauseLockedAsync(CancellationToken ct)
    {
        if (_casting)
        {
            await Cast.PauseAsync(ct).ConfigureAwait(false);
            SetState(PlayerState.Paused);
            return;
        }
        if (Engine.State is EngineState.Playing or EngineState.Pausing)
        {
            Engine.Pause(); // fades out; PausedCompletely pauses the output
            SetState(PlayerState.Paused);
        }
    }

    private async Task ResumeLockedAsync()
    {
        if (_casting)
        {
            await Cast.PlayAsync(default).ConfigureAwait(false);
            SetState(PlayerState.Playing);
            return;
        }
        Output.ResumePlayback();
        Engine.Resume();
        SetState(PlayerState.Playing);
    }

    private Task StopLockedAsync()
    {
        CancelSleepFade();
        if (_casting)
        {
            _ = Cast.StopAsync(default);
            SetState(PlayerState.Stopped);
            return Task.CompletedTask;
        }
        Engine.Stop();
        Output.Close();
        _currentSource = null;
        _pendingNext = null;
        SetState(PlayerState.Stopped);
        SaveQueueDebounced();
        return Task.CompletedTask;
    }

    private async Task NextLockedAsync(CancellationToken ct)
    {
        if (CurrentTrack is { Id: > 0 } cur && Position.TotalMilliseconds < MinPlayedMsForPlayCount)
            _pendingSkipTrackId = cur.Id;
        var entry = Queue.MoveNext(userInitiated: true);
        if (entry is null)
        {
            await StopLockedAsync().ConfigureAwait(false);
            return;
        }
        if (_casting)
        {
            await LoadOnCastLockedAsync(entry, TimeSpan.Zero, autoPlay: State != PlayerState.Paused, ct).ConfigureAwait(false);
            return;
        }
        await PlayCurrentLockedAsync(null, allowSkip: true, ct).ConfigureAwait(false);
    }

    private async Task PreviousLockedAsync(CancellationToken ct)
    {
        if (State != PlayerState.Stopped && Position > TimeSpan.FromSeconds(3))
        {
            await SeekLockedAsync(TimeSpan.Zero).ConfigureAwait(false);
            return;
        }
        var entry = Queue.MovePrevious();
        if (entry is null || State == PlayerState.Stopped && ReferenceEquals(entry, Queue.Current) && _currentSource is null && !_casting)
        {
            // Nothing was playing: start the current entry from the top.
            if (Queue.Current is not null) await PlayCurrentLockedAsync(null, allowSkip: true, ct).ConfigureAwait(false);
            return;
        }
        if (_casting)
        {
            await LoadOnCastLockedAsync(entry, TimeSpan.Zero, autoPlay: State != PlayerState.Paused, ct).ConfigureAwait(false);
            return;
        }
        await PlayCurrentLockedAsync(null, allowSkip: true, ct).ConfigureAwait(false);
    }

    private async Task SeekLockedAsync(TimeSpan position)
    {
        var clamped = position < TimeSpan.Zero ? TimeSpan.Zero : position;
        var duration = Duration;
        if (duration > TimeSpan.Zero && clamped > duration) clamped = duration;
        if (_casting)
        {
            await Cast.SeekAsync(clamped, default).ConfigureAwait(false);
        }
        else
        {
            Engine.Seek(clamped);
        }
        Smtc.UpdatePosition(clamped, duration);
        RaiseStateChanged();
    }

    // ------------------------------------------------ track loading

    private async Task PlayCurrentLockedAsync(TimeSpan? startPosition, bool allowSkip, CancellationToken ct)
    {
        var attempts = 0;
        while (true)
        {
            var entry = Queue.Current;
            if (entry is null)
            {
                SetState(PlayerState.Stopped);
                return;
            }
            var token = ++_loadToken;
            TrackSource source;
            try
            {
                source = await CreateSourceLockedAsync(entry, startPosition, ct).ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                RaiseError($"Could not open {entry.Track.DisplayTitle}: {ex.Message}", entry.Track, ex);
                if (entry.Track.Id > 0) _ = SafeRepoCallAsync(() => _tracks.RecordSkipAsync(entry.Track.Id, default));
                if (!allowSkip || ++attempts >= 3 || Queue.MoveNext(userInitiated: true) is null)
                {
                    if (attempts > 0) await StopLockedAsync().ConfigureAwait(false);
                    return;
                }
                continue;
            }
            if (token != _loadToken)
            {
                source.Dispose();
                return;
            }
            _pendingNext = null;
            _currentSource = source;
            Engine.Play(source);
            Output.ResumePlayback();
            SetState(PlayerState.Playing);
            _restoredPosition = null;
            if (startPosition > TimeSpan.Zero) Smtc.UpdatePosition(startPosition.Value, source.Duration);
            return;
        }
    }

    private async Task<TrackSource> CreateSourceLockedAsync(QueueEntry entry, TimeSpan? startPosition, CancellationToken ct)
    {
        var track = entry.Track;
        var location = await _sources.ResolveTrackAsync(track, ct).ConfigureAwait(false);
        var decoder = FFmpegDecoder.Open(location, _settings.Current.HighQualityResampler, ct);
        try
        {
            await EnsureOutputLockedAsync(decoder.Info.SampleRate, decoder.Info.Channels, ct).ConfigureAwait(false);
            var s = _settings.Current;
            var gain = ReplayGain.LinearGain(track, s.ReplayGain, s.ReplayGainPreampDb, s.ReplayGainUntaggedDb, s.ReplayGainClipPrevention);
            var bufferSeconds = location.IsRemote ? Math.Clamp(s.StreamBufferSeconds, 3, 60) : 3.0;
            var source = new TrackSource(track, entry.EntryId, decoder, Engine.SampleRate, Engine.Channels, gain, bufferSeconds);
            if (startPosition > TimeSpan.Zero) source.Seek(startPosition.Value);
            return source;
        }
        catch
        {
            decoder.Dispose();
            throw;
        }
    }

    // ------------------------------------------------ engine event handlers (on the worker)

    private Task OnTrackStarted(EngineTrackEventArgs e)
    {
        _currentSource = e.Source;
        if (e.Source.Tag is SuppressMarker) return Task.CompletedTask;
        if (e.Transition != TrackTransition.Manual && _pendingNext is { } pending && pending.EntryId == e.Source.EntryId)
        {
            for (var i = 0; i <= _pendingNextSkips; i++) Queue.MoveNext();
            _pendingNext = null;
        }
        var track = e.Source.Track;
        _restoredPosition = null;
        Smtc.UpdateTrack(track, _artwork.GetPath(track.ArtworkHash));
        Smtc.UpdatePosition(TimeSpan.Zero, e.Source.Duration);
        _dispatcher.Post(() => TrackChanged?.Invoke(this, new PlaybackTrackEventArgs(track, e.Source.EntryId)));
        if (track.IsRemote && string.IsNullOrEmpty(track.LocalCopyPath))
            _ = SafeRepoCallAsync(() => _downloads.CacheTrackAsync(track, default));
        SaveQueueDebounced();
        RaiseStateChanged();
        return Task.CompletedTask;
    }

    private Task OnTrackFinished(EngineTrackFinishedEventArgs e)
    {
        var source = e.Source;
        if (source.Tag is SuppressMarker) return Task.CompletedTask;
        var playedMs = e.PlayedFrames * 1000 / Math.Max(1, source.SampleRate);
        var track = source.Track;
        if (e.Completed || playedMs >= MinPlayedMsForPlayCount)
            _ = SafeRepoCallAsync(() => _tracks.RecordPlayAsync(track, playedMs, e.Completed, default));
        else if (_pendingSkipTrackId is { } skipId && track.Id == skipId)
            _ = SafeRepoCallAsync(() => _tracks.RecordSkipAsync(skipId, default));
        if (_pendingSkipTrackId == track.Id) _pendingSkipTrackId = null;
        return Task.CompletedTask;
    }

    private async Task OnNextTrackNeeded(TrackSource current)
    {
        if (_casting || StopAfterCurrent || _pendingNext is not null) return;
        for (var ahead = 0; ahead < 3; ahead++)
        {
            var entry = Queue.PeekAhead(ahead);
            if (entry is null) return;
            TrackSource source;
            try
            {
                source = await CreateSourceLockedAsync(entry, null, default).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                RaiseError($"Could not open {entry.Track.DisplayTitle}: {ex.Message}", entry.Track, ex);
                if (entry.Track.Id > 0) _ = SafeRepoCallAsync(() => _tracks.RecordSkipAsync(entry.Track.Id, default));
                continue;
            }
            if (!ReferenceEquals(Engine.Current, current) || _pendingNext is not null)
            {
                source.Dispose();
                return;
            }
            _pendingNext = entry;
            _pendingNextSkips = ahead;
            Engine.SetNext(source);
            // Warm the audio cache for the track after that while the network is idle.
            if (_settings.Current.PrefetchNextTrack && Queue.PeekAhead(ahead + 1) is { Track.IsRemote: true } after)
                _ = SafeRepoCallAsync(() => _downloads.CacheTrackAsync(after.Track, default));
            return;
        }
    }

    private Task OnEnded()
    {
        Interlocked.Exchange(ref _stopAfterCurrent, 0);
        _pendingNext = null;
        _currentSource = null;
        Output.Close();
        SetState(PlayerState.Stopped);
        SaveQueueDebounced();
        return Task.CompletedTask;
    }

    // ------------------------------------------------ casting

    public Task ConnectCastAsync(CastDeviceInfo device, CancellationToken ct = default) => Enqueue(async () =>
    {
        await Cast.ConnectAsync(device, ct).ConfigureAwait(false);
        _casting = true;
        _settings.Update(s => s.LastCastDeviceId = device.Id);
        CancelSleepFade();
        if (_currentSource is { } cur) cur.Tag = SuppressMarker.Instance;
        if (Engine.Next is { } nxt) nxt.Tag = SuppressMarker.Instance;
        var track = Queue.Current?.Track;
        var position = Engine.Position;
        var resume = State == PlayerState.Playing || State == PlayerState.Buffering;
        _pendingNext = null;
        Engine.Stop();
        Output.Close();
        if (track is not null)
            await LoadOnCastLockedAsync(Queue.Current!, position, resume, ct).ConfigureAwait(false);
        else
            SetState(PlayerState.Stopped);
    });

    public Task DisconnectCastAsync(bool resumeLocally = true, CancellationToken ct = default) => Enqueue(async () =>
    {
        var position = Cast.Position;
        var wasPlaying = Cast.IsPlaying;
        await Cast.DisconnectAsync(ct).ConfigureAwait(false);
        _casting = false;
        if (resumeLocally && Queue.Current is { } entry && wasPlaying)
        {
            var source = await CreateSourceLockedAsync(entry, position, ct).ConfigureAwait(false);
            source.Tag = SuppressMarker.Instance;
            _currentSource = source;
            Engine.Play(source);
            SetState(PlayerState.Playing);
        }
        else if (resumeLocally && Queue.Current is not null && State == PlayerState.Paused)
        {
            var source = await CreateSourceLockedAsync(Queue.Current, position, ct).ConfigureAwait(false);
            source.Tag = SuppressMarker.Instance;
            _currentSource = source;
            Engine.Play(source, startPaused: true);
            SetState(PlayerState.Paused);
        }
        else SetState(PlayerState.Stopped);
    });

    private async Task LoadOnCastLockedAsync(QueueEntry entry, TimeSpan position, bool autoPlay, CancellationToken ct)
    {
        SetState(PlayerState.Buffering);
        await Cast.LoadTrackAsync(entry.Track, position, autoPlay, ct).ConfigureAwait(false);
        Smtc.UpdateTrack(entry.Track, _artwork.GetPath(entry.Track.ArtworkHash));
        SetState(autoPlay ? PlayerState.Playing : PlayerState.Paused);
        _dispatcher.Post(() => TrackChanged?.Invoke(this, new PlaybackTrackEventArgs(entry.Track, entry.EntryId)));
    }

    private async Task OnCastTrackEnded()
    {
        if (Queue.Current is { } cur)
            _ = SafeRepoCallAsync(() => _tracks.RecordPlayAsync(cur.Track, cur.Track.DurationMs, completed: true, default));
        if (StopAfterCurrent)
        {
            Interlocked.Exchange(ref _stopAfterCurrent, 0);
            SetState(PlayerState.Stopped);
            return;
        }
        var entry = Queue.MoveNext();
        if (entry is null)
        {
            SetState(PlayerState.Stopped);
            return;
        }
        try
        {
            await LoadOnCastLockedAsync(entry, TimeSpan.Zero, autoPlay: true, default).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            RaiseError($"Casting {entry.Track.DisplayTitle} failed: {ex.Message}", entry.Track, ex);
            if (entry.Track.Id > 0) _ = SafeRepoCallAsync(() => _tracks.RecordSkipAsync(entry.Track.Id, default));
        }
    }

    // ------------------------------------------------ sleep timer / bookmarks

    public void SetSleepTimer(TimeSpan? duration) => Post(() =>
    {
        CancelSleepFade();
        if (duration is null || duration <= TimeSpan.Zero)
        {
            _sleepTimer?.Dispose();
            _sleepTimer = null;
            RaiseStateChanged();
            return Task.CompletedTask;
        }
        _sleepEnd = DateTimeOffset.UtcNow + duration.Value;
        _sleepTimer?.Dispose();
        _sleepTimer = new Timer(_ => Post(OnSleepTimerTick), null, TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(1));
        RaiseStateChanged();
        return Task.CompletedTask;
    });

    private Task OnSleepTimerTick()
    {
        var remaining = _sleepEnd - DateTimeOffset.UtcNow;
        if (remaining <= TimeSpan.Zero)
        {
            _sleepTimer?.Dispose();
            _sleepTimer = null;
            Engine.FadeGain = 1f;
            return PauseLockedAsync(default);
        }
        if (remaining <= TimeSpan.FromSeconds(10) && !_casting)
            Engine.FadeGain = (float)(remaining.TotalSeconds / 10);
        RaiseStateChanged();
        return Task.CompletedTask;
    }

    private void CancelSleepFade() => Engine.FadeGain = 1f;

    public Task<Bookmark?> AddBookmarkAsync(string? note = null, CancellationToken ct = default) =>
        Enqueue(async () =>
        {
            if (CurrentTrack is not { } track || State == PlayerState.Stopped) return (Bookmark?)null;
            return await _bookmarks.AddAsync(track, (long)Position.TotalMilliseconds, note, ct).ConfigureAwait(false);
        });

    public Task GoToBookmarkAsync(Bookmark bookmark, CancellationToken ct = default) => Enqueue(async () =>
    {
        var current = Queue.Current?.Track;
        if (current is not null && current.SourceUri == bookmark.SourceUri && current.CueStartMs == bookmark.CueStartMs && State != PlayerState.Stopped)
        {
            await SeekLockedAsync(bookmark.Position).ConfigureAwait(false);
            return;
        }
        for (var i = 0; i < Queue.Items.Count; i++)
        {
            var t = Queue.Items[i].Track;
            if (t.SourceUri == bookmark.SourceUri && t.CueStartMs == bookmark.CueStartMs)
            {
                Queue.JumpTo(i);
                await PlayCurrentLockedAsync(bookmark.Position, allowSkip: false, ct).ConfigureAwait(false);
                return;
            }
        }
        var track = new Track
        {
            Id = bookmark.TrackId ?? 0,
            SourceUri = bookmark.SourceUri,
            CueStartMs = bookmark.CueStartMs,
            Title = bookmark.TrackTitle,
            Artist = bookmark.TrackArtist,
            FileName = SourceUris.FileNameOf(bookmark.SourceUri)
        };
        Queue.Set(new[] { track });
        await PlayCurrentLockedAsync(bookmark.Position, allowSkip: false, ct).ConfigureAwait(false);
    });

    // ------------------------------------------------ output / settings

    public IReadOnlyList<OutputDeviceInfo> GetOutputDevices() => Output.GetDevices();

    public Task ReopenOutputAsync() => Enqueue(() => ReopenOutputLockedAsync(0, 0, default));

    private async Task EnsureOutputLockedAsync(int sourceRate, int sourceChannels, CancellationToken ct)
    {
        if (_openingOutput) return;
        var s = _settings.Current;
        if (Output.IsOpen)
        {
            // Exclusive "match source" mode: reopen when the rate changes between tracks.
            var rateSwitch = s.ExclusiveMode && s.OutputSampleRate == 0 && sourceRate > 0 && Output.Format is { } f &&
                             (f.SampleRate != sourceRate || (sourceChannels > 0 && f.Channels != sourceChannels));
            if (!rateSwitch) return;
        }
        await ReopenOutputLockedAsync(sourceRate, sourceChannels, ct).ConfigureAwait(false);
    }

    private async Task ReopenOutputLockedAsync(int sourceRate, int sourceChannels, CancellationToken ct)
    {
        if (_openingOutput) return;
        _openingOutput = true;
        try
        {
            var s = _settings.Current;
            var position = Engine.Position;
            var wasPlaying = Engine.State is EngineState.Playing or EngineState.Pausing;
            var currentEntry = Engine.Current is not null ? Queue.Current : null;
            Output.Close();
            var format = Output.Prepare(s.OutputDeviceId, s.ExclusiveMode, s.OutputSampleRate, sourceRate, sourceChannels, Math.Clamp(s.OutputBufferMs, 20, 500));
            if (format.SampleRate != Engine.SampleRate || format.Channels != Engine.Channels)
            {
                if (Engine.Current is { } oldCurrent) oldCurrent.Tag = SuppressMarker.Instance;
                if (Engine.Next is { } oldNext) oldNext.Tag = SuppressMarker.Instance;
                Engine.Stop();
                Engine.Configure(format.SampleRate, format.Channels);
                _pendingNext = null;
                if (currentEntry is not null)
                {
                    var source = await CreateSourceLockedAsync(currentEntry, position > TimeSpan.FromMilliseconds(500) ? position : null, ct).ConfigureAwait(false);
                    source.Tag = SuppressMarker.Instance;
                    _currentSource = source;
                    Engine.Play(source, startPaused: !wasPlaying);
                }
            }
            ApplySettingsToEngine(s);
            Output.Start(Engine);
            if (!wasPlaying && Engine.Current is not null) Output.PausePlayback();
        }
        finally
        {
            _openingOutput = false;
        }
    }

    private void ApplySettingsToEngine(AppSettings s)
    {
        Engine.Gapless = s.Gapless;
        Engine.CrossfadeSeconds = s.CrossfadeSeconds;
        Engine.Speed = Math.Clamp(s.Speed, WsolaTimeStretcher.MinSpeed, WsolaTimeStretcher.MaxSpeed);
        Engine.Volume = s.Volume;
        Engine.Muted = s.Muted;
        Engine.Dsp.SetEqualizer(s.EqEnabled, s.EqPreampDb, s.EqBands);
        Engine.Dsp.SetLoudness(s.LoudnessBoostEnabled, s.LoudnessBoostDb);
        try { Engine.Dsp.SetChainJson(s.DspChainEnabled, s.DspChainJson); }
        catch (Exception ex) { _log.LogWarning(ex, "The DSP chain JSON could not be applied"); }
    }

    private void OnSettingsChanged(AppSettings old, AppSettings s)
    {
        if (_casting) { ApplyCastSettings(s); return; }
        ApplySettingsToEngine(s);
        if (old.ReplayGain != s.ReplayGain || old.ReplayGainPreampDb != s.ReplayGainPreampDb ||
            old.ReplayGainUntaggedDb != s.ReplayGainUntaggedDb || old.ReplayGainClipPrevention != s.ReplayGainClipPrevention)
        {
            if (Engine.Current is { } cur) cur.Gain = ReplayGain.LinearGain(cur.Track, s.ReplayGain, s.ReplayGainPreampDb, s.ReplayGainUntaggedDb, s.ReplayGainClipPrevention);
            if (Engine.Next is { } next) next.Gain = ReplayGain.LinearGain(next.Track, s.ReplayGain, s.ReplayGainPreampDb, s.ReplayGainUntaggedDb, s.ReplayGainClipPrevention);
        }
        if (old.OutputDeviceId != s.OutputDeviceId || old.ExclusiveMode != s.ExclusiveMode ||
            old.OutputSampleRate != s.OutputSampleRate || old.OutputBufferMs != s.OutputBufferMs)
        {
            Post(async () =>
            {
                try { await ReopenOutputLockedAsync(_currentSource?.Info.SampleRate ?? 0, _currentSource?.Info.Channels ?? 0, default).ConfigureAwait(false); }
                catch (Exception ex) { RaiseError("Could not open the audio output: " + ex.Message, CurrentTrack, ex); }
            });
        }
    }

    private void ApplyCastSettings(AppSettings s)
    {
        _ = SafeRepoCallAsync(async () =>
        {
            await Cast.SetVolumeAsync(s.Volume).ConfigureAwait(false);
            await Cast.SetMutedAsync(s.Muted).ConfigureAwait(false);
        });
    }

    // ------------------------------------------------ queue persistence / helpers

    private void SaveQueueDebounced() => _queueSaveTimer.Change(1200, Timeout.Infinite);

    private async Task SaveQueueNowAsync()
    {
        _queueSaveTimer.Change(Timeout.Infinite, Timeout.Infinite);
        try
        {
            if (!_settings.Current.RememberQueue) return;
            var snapshot = _queueStore.Capture(Queue, (long)Position.TotalMilliseconds);
            await _queueStore.SaveAsync(snapshot).ConfigureAwait(false);
        }
        catch (Exception ex) { _log.LogDebug(ex, "Saving the queue failed"); }
    }

    private async Task SafeRepoCallAsync(Func<Task> call)
    {
        try { await call().ConfigureAwait(false); }
        catch (Exception ex) { _log.LogDebug(ex, "Background repository call failed"); }
    }

    private void SetState(PlayerState state)
    {
        if (Interlocked.Exchange(ref _state, (int)state) == (int)state) return;
        RaiseStateChanged();
        Smtc.UpdatePlaybackStatus(state, Engine.IsBuffering);
    }

    private void RaiseStateChanged() => _dispatcher.Post(() => StateChanged?.Invoke(this, EventArgs.Empty));

    private void RaiseError(string message, Track? track, Exception? ex)
    {
        _log.LogWarning(ex, "{Message}", message);
        _dispatcher.Post(() => PlaybackError?.Invoke(this, new PlaybackErrorEventArgs(message, track, ex)));
    }

    private void Post(Func<Task> action) => _work.Writer.TryWrite(action);

    private Task Enqueue(Func<Task> action)
    {
        var tcs = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!_work.Writer.TryWrite(async () =>
            {
                try
                {
                    await action().ConfigureAwait(false);
                    tcs.TrySetResult();
                }
                catch (Exception ex)
                {
                    _log.LogError(ex, "Playback operation failed");
                    RaiseError(ex.Message, CurrentTrack, ex);
                    tcs.TrySetException(ex);
                }
            }))
            tcs.TrySetException(new InvalidOperationException("The playback service is disposed."));
        return tcs.Task;
    }

    private Task<T> Enqueue<T>(Func<Task<T>> action)
    {
        var tcs = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!_work.Writer.TryWrite(async () =>
            {
                try { tcs.TrySetResult(await action().ConfigureAwait(false)); }
                catch (Exception ex)
                {
                    _log.LogError(ex, "Playback operation failed");
                    RaiseError(ex.Message, CurrentTrack, ex);
                    tcs.TrySetException(ex);
                }
            }))
            tcs.TrySetException(new InvalidOperationException("The playback service is disposed."));
        return tcs.Task;
    }

    private async Task WorkerLoopAsync()
    {
        await foreach (var action in _work.Reader.ReadAllAsync().ConfigureAwait(false))
        {
            try { await action().ConfigureAwait(false); }
            catch (Exception ex) { _log.LogError(ex, "Playback worker item failed"); }
        }
    }

    public async Task FlushAsync()
    {
        await Enqueue(SaveQueueNowAsync).ConfigureAwait(false);
        await _settings.FlushAsync().ConfigureAwait(false);
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed) return;
        _disposed = true;
        _positionSaveTimer.Dispose();
        _sleepTimer?.Dispose();
        try { await FlushAsync().ConfigureAwait(false); } catch (Exception ex) { _log.LogDebug(ex, "Final flush failed"); }
        _work.Writer.TryComplete();
        try { await _worker.WaitAsync(TimeSpan.FromSeconds(10)).ConfigureAwait(false); }
        catch (TimeoutException) { _log.LogWarning("The playback worker did not stop in time"); }
        _queueSaveTimer.Dispose();
        Smtc.Dispose();
        await Cast.DisposeAsync().ConfigureAwait(false);
        Output.Dispose();
        Engine.Dispose();
    }
}
