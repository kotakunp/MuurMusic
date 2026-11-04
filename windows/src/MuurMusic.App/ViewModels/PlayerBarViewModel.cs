using CommunityToolkit.Mvvm.ComponentModel;
using Microsoft.Extensions.DependencyInjection;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Dispatching;
using MuurMusic.App.Services;
using MuurMusic.Audio.Playback;
using MuurMusic.Core.Models;
using MuurMusic.Core.Settings;
using MuurMusic.Core.Tags;

namespace MuurMusic.App.ViewModels;

/// <summary>
/// View model behind the persistent transport bar: play/pause, seek, shuffle/repeat, stop-after-current,
/// skip back/forward, volume, output device, speed, sleep timer, casting and the "FLAC 24/96 -> ..." info line.
/// </summary>
public sealed partial class PlayerBarViewModel : ObservableObject, IDisposable
{
    private readonly IPlaybackService _playback;
    private readonly ISettingsService _settings;
    private readonly IArtworkCache _artwork;
    private readonly NotificationService _notifications;
    private readonly ToastService _toast;
    private readonly TaskbarService _taskbar;
    private readonly DispatcherQueueTimer _timer;
    private bool _seeking;
    private double _seekValue;

    public PlayerBarViewModel(IPlaybackService playback, ISettingsService settings, IArtworkCache artwork,
        NotificationService notifications, ToastService toast, TaskbarService taskbar)
    {
        _playback = playback;
        _settings = settings;
        _artwork = artwork;
        _notifications = notifications;
        _toast = toast;
        _taskbar = taskbar;

        Queue = new QueueViewModel(playback, notifications, App.Services.GetRequiredService<MuurMusic.Core.Data.IPlaylistRepository>());

        playback.StateChanged += (_, _) => RefreshState();
        playback.TrackChanged += (_, e) => OnTrackChanged(e.Track);
        playback.QueueChanged += (_, _) => RefreshQueueSummary();
        playback.OutputDevicesChanged += (_, _) => RefreshDevices();
        playback.PlaybackError += (_, e) => _notifications.Error("Playback error", e.Message);
        playback.Cast.ActiveDeviceChanged += (_, _) => RefreshCast();
        playback.Cast.SessionStateChanged += (_, _) => RefreshState();

        _timer = DispatcherQueue.GetForCurrentThread().CreateTimer();
        _timer.Interval = TimeSpan.FromMilliseconds(250);
        _timer.Tick += (_, _) => Tick();
        _timer.Start();

        RefreshState();
        RefreshDevices();
        RefreshCast();
    }

    public QueueViewModel Queue { get; }

    // ------------------------------------------------ state

    [ObservableProperty] private string _trackTitle = "Nothing playing";
    [ObservableProperty] private string _trackArtist = "Pick a song and press play";
    [ObservableProperty] private string? _artworkPath;
    [ObservableProperty] private bool _hasTrack;
    [ObservableProperty] private bool _isPlaying;
    [ObservableProperty] private bool _isBuffering;
    [ObservableProperty] private string _playPauseGlyph = "\uE768";
    [ObservableProperty] private string _positionText = "0:00";
    [ObservableProperty] private string _durationText = "0:00";
    [ObservableProperty] private double _durationSeconds;
    [ObservableProperty] private double _positionSeconds;
    [ObservableProperty] private bool _isFavorite;
    [ObservableProperty] private bool _shuffleOn;
    [ObservableProperty] private string _repeatGlyph = "\uE8EE";
    [ObservableProperty] private bool _repeatOne;
    [ObservableProperty] private bool _repeatAll;
    [ObservableProperty] private bool _stopAfterCurrent;
    [ObservableProperty] private string _speedText = "1.0\u00D7";
    [ObservableProperty] private string _sleepTimerText = "";
    [ObservableProperty] private bool _hasSleepTimer;
    [ObservableProperty] private string _outputInfo = "";
    [ObservableProperty] private string _deviceName = "Default output";
    [ObservableProperty] private bool _isExclusive;
    [ObservableProperty] private bool _isCasting;
    [ObservableProperty] private string? _castDeviceName;
    [ObservableProperty] private string _qualityBadge = "";

    public double VolumePercent
    {
        get => _playback.Volume * 100;
        set
        {
            _playback.Volume = value / 100.0;
            OnPropertyChanged();
            OnPropertyChanged(nameof(VolumePercentText));
            OnPropertyChanged(nameof(VolumeGlyph));
        }
    }

    public string VolumePercentText => $"{(int)Math.Round(VolumePercent)}%";
    public string ExclusiveLabel => IsExclusive ? "Exclusive mode: on" : "Exclusive mode: off";

    public bool IsMuted
    {
        get => _playback.Muted;
        set { _playback.Muted = value; OnPropertyChanged(); OnPropertyChanged(nameof(VolumeGlyph)); }
    }

    public string VolumeGlyph => IsMuted || VolumePercent < 1 ? "\uE74F" : VolumePercent < 50 ? "\uE993" : "\uE995";

    public double SeekSliderValue
    {
        get => _seeking ? _seekValue : PositionSeconds;
        set
        {
            if (_seeking) { _seekValue = value; OnPropertyChanged(nameof(PositionText)); }
        }
    }

    public IReadOnlyList<MuurMusic.Audio.Output.OutputDeviceInfo> OutputDevices { get; private set; } = Array.Empty<MuurMusic.Audio.Output.OutputDeviceInfo>();

    public int SkipBackSeconds => _settings.Current.SkipBackSeconds;
    public int SkipForwardSeconds => _settings.Current.SkipForwardSeconds;
    public string SkipBackLabel => $"\u21BA{SkipBackSeconds}";
    public string SkipForwardLabel => $"{SkipForwardSeconds}\u21BB";
    public string SkipBackName => $"Skip back {SkipBackSeconds} seconds";
    public string SkipForwardName => $"Skip forward {SkipForwardSeconds} seconds";
    public string IsFavoriteGlyph => IsFavorite ? "\uE735" : "\uE734";

    private static Microsoft.UI.Xaml.Media.Brush Res(string key) =>
        (Microsoft.UI.Xaml.Media.Brush)Microsoft.UI.Xaml.Application.Current.Resources[key];

    public Microsoft.UI.Xaml.Media.Brush ShuffleBrush => Res(ShuffleOn ? "MuurAccentBrush" : "MuurTextSecondaryBrush");
    public Microsoft.UI.Xaml.Media.Brush RepeatBrush => Res(RepeatOne || RepeatAll ? "MuurAccentBrush" : "MuurTextSecondaryBrush");
    public Microsoft.UI.Xaml.Media.Brush StopAfterBrush => Res(StopAfterCurrent ? "MuurAccentBrush" : "MuurTextSecondaryBrush");
    public Microsoft.UI.Xaml.Media.Brush CastBrush => Res(IsCasting ? "MuurAccentBrush" : "MuurTextSecondaryBrush");

    partial void OnIsFavoriteChanged(bool value) => OnPropertyChanged(nameof(IsFavoriteGlyph));
    partial void OnShuffleOnChanged(bool value) => OnPropertyChanged(nameof(ShuffleBrush));
    partial void OnStopAfterCurrentChanged(bool value) => OnPropertyChanged(nameof(StopAfterBrush));
    partial void OnIsCastingChanged(bool value) => OnPropertyChanged(nameof(CastBrush));

    private void RaiseRepeatBrushes()
    {
        OnPropertyChanged(nameof(RepeatBrush));
        OnPropertyChanged(nameof(RepeatGlyph));
    }

    private void Tick()
    {
        if (_seeking)
        {
            PositionText = Format(TimeSpan.FromSeconds(_seekValue));
        }
        else
        {
            var pos = _playback.Position;
            PositionSeconds = pos.TotalSeconds;
            PositionText = Format(pos);
        }
        DurationSeconds = Math.Max(0, _playback.Duration.TotalSeconds);
        DurationText = Format(_playback.Duration);
        OnPropertyChanged(nameof(SeekSliderValue));

        var remaining = _playback.SleepTimerRemaining;
        HasSleepTimer = remaining is not null;
        SleepTimerText = remaining is { } r ? $"{(int)r.TotalMinutes}:{r.Seconds:00}" : "";

        RefreshOutputInfo();
        _taskbar.UpdateProgress(_playback.Position, _playback.Duration, _playback.State);
    }

    private static string Format(TimeSpan t) =>
        t.TotalHours >= 1 ? $"{(int)t.TotalHours}:{t.Minutes:00}:{t.Seconds:00}" : $"{t.Minutes}:{t.Seconds:00}";

    private void OnTrackChanged(Track track)
    {
        HasTrack = true;
        TrackTitle = track.DisplayTitle;
        TrackArtist = track.DisplayArtist;
        IsFavorite = track.Favorite;
        QualityBadge = track.QualityBadge;
        ArtworkPath = track.ArtworkHash is { } h ? _artwork.GetThumbnailPath(h, 96) : null;
        if (ArtworkPath is null && track.ArtworkUrl is { } url)
        {
            _ = Task.Run(async () =>
            {
                var hash = await _artwork.StoreFromUrlAsync(url).ConfigureAwait(false);
                if (hash is not null)
                    App.CurrentWindow?.DispatcherQueue.TryEnqueue(() => ArtworkPath = _artwork.GetThumbnailPath(hash, 96));
            });
        }
        _toast.TrackChanged(track, ArtworkPath);
        RefreshState();
        RefreshOutputInfo();
    }

    private void RefreshState()
    {
        var state = _playback.State;
        IsPlaying = state == PlayerState.Playing;
        IsBuffering = _playback.IsBuffering;
        PlayPauseGlyph = IsPlaying || state == PlayerState.Buffering ? "\uE769" : "\uE768";
        ShuffleOn = _playback.Shuffle;
        RepeatOne = _playback.Repeat == RepeatMode.One;
        RepeatAll = _playback.Repeat == RepeatMode.All;
        RepeatGlyph = _playback.Repeat == RepeatMode.One ? "\uE8ED" : "\uE8EE";
        RaiseRepeatBrushes();
        StopAfterCurrent = _playback.StopAfterCurrent;
        SpeedText = $"{_playback.Speed:0.0#}\u00D7";
        HasTrack = _playback.CurrentTrack is not null;
        if (_playback.CurrentTrack is { } t && TrackTitle != t.DisplayTitle) OnTrackChanged(t);
        IsCasting = _playback.IsCasting;
        OnPropertyChanged(nameof(VolumePercent));
        OnPropertyChanged(nameof(VolumeGlyph));
        _taskbar.UpdatePlayPauseIcon();
    }

    private void RefreshQueueSummary() { }

    private void RefreshDevices()
    {
        OutputDevices = _playback.GetOutputDevices();
        OnPropertyChanged(nameof(OutputDevices));
        var active = OutputDevices.FirstOrDefault(d => d.IsActive);
        DeviceName = active?.FriendlyName ?? "Default output";
        IsExclusive = _settings.Current.ExclusiveMode;
        RefreshOutputInfo();
    }

    private void RefreshCast()
    {
        IsCasting = _playback.IsCasting;
        CastDeviceName = _playback.Cast.ActiveDevice?.Name;
        RefreshOutputInfo();
    }

    private void RefreshOutputInfo()
    {
        var track = _playback.CurrentTrack;
        if (track is null) { OutputInfo = ""; return; }
        var source = track.QualityBadge;
        var fmt = _playback.Output.Format;
        string output;
        if (IsCasting && CastDeviceName is { } cast)
        {
            output = $"casting to {cast}";
        }
        else if (fmt is not null && _playback.Output.IsOpen)
        {
            var bits = fmt.ValidBits > 0 ? fmt.ValidBits : 32;
            var rate = fmt.SampleRate >= 1000 ? $"{fmt.SampleRate / 1000.0:0.#} kHz" : $"{fmt.SampleRate} Hz";
            var mode = fmt.Exclusive ? "exclusive" : "shared";
            output = $"{bits}-bit {rate} {mode} \u00B7 {DeviceName}";
        }
        else output = DeviceName;
        OutputInfo = $"{source}  \u2192  {output}";
    }

    // ------------------------------------------------ seek

    public void BeginSeek() => _seeking = true;

    public void EndSeek(double seconds)
    {
        _seeking = false;
        _seekValue = seconds;
        if (HasTrack) _ = _playback.SeekAsync(TimeSpan.FromSeconds(seconds));
    }

    // ------------------------------------------------ commands

    [RelayCommand] private Task TogglePlayPause() => _playback.TogglePlayPauseAsync();
    [RelayCommand] private Task Next() => _playback.NextAsync();
    [RelayCommand] private Task Previous() => _playback.PreviousAsync();
    [RelayCommand] private Task Stop() => _playback.StopAsync();
    [RelayCommand] private Task SkipBack() => _playback.SkipBackAsync();
    [RelayCommand] private Task SkipForward() => _playback.SkipForwardAsync();

    [RelayCommand]
    private void ToggleShuffle() => _playback.Shuffle = !_playback.Shuffle;

    [RelayCommand]
    private void CycleRepeat() =>
        _playback.Repeat = _playback.Repeat switch
        {
            RepeatMode.Off => RepeatMode.All,
            RepeatMode.All => RepeatMode.One,
            _ => RepeatMode.Off,
        };

    [RelayCommand]
    private void ToggleStopAfterCurrent()
    {
        _playback.StopAfterCurrent = !_playback.StopAfterCurrent;
        if (_playback.StopAfterCurrent) _notifications.Info("Stop after current", "Playback stops when this track ends.");
    }

    [RelayCommand]
    private void SetSpeed(string speed)
    {
        if (double.TryParse(speed, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var s))
            _playback.Speed = s;
        SpeedText = $"{_playback.Speed:0.0#}\u00D7";
    }

    [RelayCommand]
    private void SetSleepTimer(string minutes)
    {
        if (minutes == "off") { _playback.SetSleepTimer(null); _notifications.Info("Sleep timer off"); return; }
        if (int.TryParse(minutes, out var m))
        {
            _playback.SetSleepTimer(TimeSpan.FromMinutes(m));
            _notifications.Info("Sleep timer", $"Playback pauses in {m} minutes.");
        }
    }

    [RelayCommand]
    private async Task ToggleFavorite()
    {
        var track = _playback.CurrentTrack;
        if (track is null || track.Id <= 0) return;
        var repo = App.Services.GetRequiredService<MuurMusic.Core.Data.ITrackRepository>();
        var fav = !track.Favorite;
        await repo.SetFavoriteAsync(track.Id, fav);
        track.Favorite = fav;
        IsFavorite = fav;
    }

    [RelayCommand]
    private async Task SelectOutputDevice(MuurMusic.Audio.Output.OutputDeviceInfo? device)
    {
        _settings.Update(s => s.OutputDeviceId = device?.IsDefault == true ? null : device?.Id);
        await Task.Delay(400);
        RefreshDevices();
    }

    [RelayCommand]
    private void ToggleExclusive()
    {
        _settings.Update(s => s.ExclusiveMode = !s.ExclusiveMode);
        IsExclusive = _settings.Current.ExclusiveMode;
        _notifications.Info("Output mode", IsExclusive
            ? "Exclusive (WASAPI) — bit-perfect, MuurMusic owns the device."
            : "Shared (WASAPI) — other apps can play at the same time.");
        OnPropertyChanged(nameof(ExclusiveLabel));
    }

    // ------------------------------------------------ casting

    public System.Collections.ObjectModel.ObservableCollection<MuurMusic.Audio.Casting.CastDeviceInfo> CastDevices { get; } = new();

    [ObservableProperty] private bool _isDiscoveringCast;

    [RelayCommand]
    private async Task DiscoverCastDevices()
    {
        IsDiscoveringCast = true;
        CastDevices.Clear();
        try
        {
            var found = await _playback.Cast.DiscoverAsync(TimeSpan.FromSeconds(4));
            foreach (var d in found) CastDevices.Add(d);
            if (CastDevices.Count == 0) _notifications.Info("No cast devices found", "Make sure your Chromecast or DLNA device is on the same network.");
        }
        catch (Exception ex)
        {
            _notifications.Error("Cast discovery failed", ex.Message);
        }
        finally { IsDiscoveringCast = false; }
    }

    [RelayCommand]
    private async Task ConnectCast(MuurMusic.Audio.Casting.CastDeviceInfo? device)
    {
        if (device is null) return;
        try
        {
            await _playback.ConnectCastAsync(device);
            _settings.Update(s => s.LastCastDeviceId = device.Id);
            _notifications.Success("Casting", $"Playing on {device.Name}.");
        }
        catch (Exception ex)
        {
            _notifications.Error("Could not connect", ex.Message);
        }
        RefreshCast();
    }

    [RelayCommand]
    private async Task DisconnectCast()
    {
        try { await _playback.DisconnectCastAsync(resumeLocally: true); }
        catch (Exception ex) { _notifications.Error("Could not stop casting", ex.Message); }
        RefreshCast();
    }

    [RelayCommand]
    private async Task AddBookmark()
    {
        var bookmark = await _playback.AddBookmarkAsync();
        _notifications.Success("Bookmark saved", bookmark is null ? null : $"At {Format(bookmark.Position)}");
    }

    public void Dispose() => _timer.Stop();
}
