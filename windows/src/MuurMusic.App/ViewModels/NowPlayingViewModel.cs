using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Dispatching;
using MuurMusic.App.Services;
using MuurMusic.Audio.Playback;
using MuurMusic.Core.Lyrics;
using MuurMusic.Core.Models;
using MuurMusic.Core.Settings;
using MuurMusic.Core.Tags;

namespace MuurMusic.App.ViewModels;

public sealed partial class LyricLineViewModel : ObservableObject
{
    public required LyricLine Line { get; init; }
    public int Index { get; init; }
    public string Text => Line.Text;
    public bool HasTime => Line.TimeMs.HasValue;

    [ObservableProperty] private bool _isActive;

    /// <summary>Accent when active, dimmed otherwise.</summary>
    public Microsoft.UI.Xaml.Media.Brush Foreground => IsActive
        ? (Microsoft.UI.Xaml.Media.Brush)Microsoft.UI.Xaml.Application.Current.Resources["MuurForegroundBrush"]
        : (Microsoft.UI.Xaml.Media.Brush)Microsoft.UI.Xaml.Application.Current.Resources["MuurSecondaryBrush"];

    public Windows.UI.Text.FontWeight Weight => IsActive ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal;

    partial void OnIsActiveChanged(bool value)
    {
        OnPropertyChanged(nameof(Foreground));
        OnPropertyChanged(nameof(Weight));
    }
}

/// <summary>Now Playing: artwork/vinyl/visualizer styles, queue-adjacent metadata, synced lyrics panel.</summary>
public sealed partial class NowPlayingViewModel : ObservableObject, IDisposable
{
    private readonly IPlaybackService _playback;
    private readonly ISettingsService _settings;
    private readonly ILyricsService _lyrics;
    private readonly IArtworkCache _artwork;
    private readonly NotificationService _notifications;
    private readonly DispatcherQueueTimer _timer;
    private Track? _lastTrack;
    private LyricsDocument? _document;
    private int _activeLine = -1;
    private bool _loadingLyrics;

    public NowPlayingViewModel(IPlaybackService playback, ISettingsService settings, ILyricsService lyrics, IArtworkCache artwork, NotificationService notifications)
    {
        _playback = playback;
        _settings = settings;
        _lyrics = lyrics;
        _artwork = artwork;
        _notifications = notifications;
        _timer = DispatcherQueue.GetForCurrentThread().CreateTimer();
        _timer.Interval = TimeSpan.FromMilliseconds(120);
        _timer.Tick += (_, _) => Tick();
        playback.TrackChanged += (_, _) => DispatcherQueue.GetForCurrentThread().TryEnqueue(async () => await OnTrackChangedAsync());
        playback.StateChanged += (_, _) => UpdateState();
        playback.QueueChanged += (_, _) => DispatcherQueue.GetForCurrentThread().TryEnqueue(UpdateUpNext);
        UpdateState();
        UpdateUpNext();
    }

    public ObservableCollection<LyricLineViewModel> Lines { get; } = new();
    public ObservableCollection<UpNextItem> UpNext { get; } = new();

    [ObservableProperty] private string _title = "";
    [ObservableProperty] private string _artistAlbum = "";
    [ObservableProperty] private string _qualityBadge = "";
    [ObservableProperty] private string? _artworkPath;
    [ObservableProperty] private bool _hasTrack;
    [ObservableProperty] private bool _isPlaying;
    [ObservableProperty] private string _styleKey = "Artwork";
    [ObservableProperty] private bool _showArtworkStyle = true;
    [ObservableProperty] private bool _showVinylStyle;
    [ObservableProperty] private bool _showVisualizerStyle;
    [ObservableProperty] private bool _vinylSpin = true;
    [ObservableProperty] private string _lyricsStatus = "";
    [ObservableProperty] private bool _hasLyrics;
    [ObservableProperty] private bool _showPlainLyrics;
    [ObservableProperty] private string _plainLyrics = "";
    [ObservableProperty] private long _offsetMs;
    [ObservableProperty] private bool _isLoadingLyrics;
    [ObservableProperty] private string _activeLineText = "";

    /// <summary>True when neither synced nor plain lyrics are showing.</summary>
    public bool ShowNoLyrics => HasTrack && !HasLyrics && !ShowPlainLyrics;
    partial void OnHasLyricsChanged(bool value) => OnPropertyChanged(nameof(ShowNoLyrics));
    partial void OnShowPlainLyricsChanged(bool value) => OnPropertyChanged(nameof(ShowNoLyrics));
    partial void OnHasTrackChanged(bool value) => OnPropertyChanged(nameof(ShowNoLyrics));

    /// <summary>Active lyric index for auto-scroll (-1 none).</summary>
    [ObservableProperty] private int _activeLineIndex = -1;

    public void Start()
    {
        _timer.Start();
        _ = OnTrackChangedAsync(force: true);
    }

    public void Stop() => _timer.Stop();

    public void ApplyStyle(string style)
    {
        StyleKey = style;
        ShowArtworkStyle = style == "Artwork";
        ShowVinylStyle = style == "Vinyl";
        ShowVisualizerStyle = style == "Visualizer";
        _settings.Update(s => s.NowPlayingStyle = style);
    }

    public string[] StyleOptions => new[] { "Artwork", "Vinyl", "Visualizer" };

    private void Tick()
    {
        if (_document is not { IsSynced: true }) return;
        var posMs = (long)_playback.Position.TotalMilliseconds;
        var idx = _document.LineIndexAt(posMs);
        if (idx == _activeLine) return;
        _activeLine = idx;
        for (var i = 0; i < Lines.Count; i++) Lines[i].IsActive = i == idx;
        ActiveLineIndex = idx;
        ActiveLineText = idx >= 0 && idx < Lines.Count ? Lines[idx].Text : "";
    }

    private void UpdateState()
    {
        IsPlaying = _playback.State == PlayerState.Playing;
        VinylSpin = IsPlaying && ShowVinylStyle;
    }

    private void UpdateUpNext()
    {
        UpNext.Clear();
        var queue = _playback.Queue;
        // Walk the play order from the current position so shuffle is reflected.
        for (var pos = queue.OrderPosition + 1; pos < queue.Order.Count && UpNext.Count < 6; pos++)
        {
            var entry = queue.Items[queue.Order[pos]];
            UpNext.Add(new UpNextItem(entry.Track, _artwork.GetThumbnailPath(entry.Track.ArtworkHash, 64), entry.EntryId));
        }
    }

    private async Task OnTrackChangedAsync(bool force = false)
    {
        var track = _playback.CurrentTrack;
        if (!force && ReferenceEquals(track, _lastTrack)) return;
        _lastTrack = track;
        HasTrack = track is not null;
        Title = track?.DisplayTitle ?? "Nothing playing";
        ArtistAlbum = track is null ? "" : $"{track.DisplayArtist}{(string.IsNullOrEmpty(track.DisplayAlbum) ? "" : " \u00B7 " + track.DisplayAlbum)}";
        QualityBadge = track?.QualityBadge ?? "";
        ArtworkPath = track is null ? null : _artwork.GetPath(track.ArtworkHash) ?? _artwork.GetThumbnailPath(track.ArtworkHash, 512);
        await LoadLyricsAsync(track);
    }

    private async Task LoadLyricsAsync(Track? track)
    {
        Lines.Clear();
        _document = null;
        _activeLine = -1;
        ActiveLineIndex = -1;
        HasLyrics = false;
        ShowPlainLyrics = false;
        PlainLyrics = "";
        LyricsStatus = track is null ? "" : "No lyrics yet \u2014 tap Find lyrics to look online.";
        if (track is null) return;

        IsLoadingLyrics = true;
        var result = await _lyrics.GetAsync(track, allowOnline: false);
        IsLoadingLyrics = false;
        ApplyLyrics(result);

        OffsetMs = await _lyrics.GetOffsetAsync(track);
    }

    private void ApplyLyrics(LyricsResult? result)
    {
        Lines.Clear();
        if (result is null || !result.Found || result.Document.IsEmpty)
        {
            LyricsStatus = "No lyrics saved for this track yet.";
            HasLyrics = false;
            ShowPlainLyrics = false;
            _document = null;
            return;
        }
        _document = result.Document;
        HasLyrics = true;
        if (result.Document.IsSynced)
        {
            ShowPlainLyrics = false;
            LyricsStatus = "";
            var i = 0;
            foreach (var line in result.Document.Lines)
            {
                if (string.IsNullOrWhiteSpace(line.Text)) continue;
                Lines.Add(new LyricLineViewModel { Line = line, Index = i++ });
            }
            if (Lines.Count == 0)
            {
                HasLyrics = false;
                LyricsStatus = "This lyrics file has no singable lines.";
            }
        }
        else
        {
            ShowPlainLyrics = true;
            PlainLyrics = result.Document.ToPlainText();
            LyricsStatus = "";
        }
    }

    [RelayCommand]
    private async Task FindOnline()
    {
        if (_playback.CurrentTrack is not { } track || _loadingLyrics) return;
        _loadingLyrics = true;
        IsLoadingLyrics = true;
        LyricsStatus = "Searching LRCLIB\u2026";
        try
        {
            var result = await _lyrics.FetchOnlineAsync(track);
            if (result is { Found: true })
            {
                ApplyLyrics(result);
                _notifications.Success("Lyrics found", track.DisplayTitle);
            }
            else
            {
                LyricsStatus = "No lyrics found online for this one. The cat is silent.";
            }
        }
        catch (Exception ex)
        {
            LyricsStatus = $"Lyrics lookup failed: {ex.Message}";
        }
        finally
        {
            _loadingLyrics = false;
            IsLoadingLyrics = false;
        }
    }

    [RelayCommand]
    private async Task NudgeOffset(int deltaMs)
    {
        if (_playback.CurrentTrack is not { } track) return;
        OffsetMs += deltaMs;
        _document?.Shift(deltaMs);
        _activeLine = -1;
        await _lyrics.SetOffsetAsync(track, OffsetMs);
    }

    public async Task SeekToLineAsync(LyricLineViewModel? line)
    {
        if (line?.Line.TimeMs is { } ms)
            await _playback.SeekAsync(TimeSpan.FromMilliseconds(ms));
    }

    public async Task PlayUpNextAsync(UpNextItem? item)
    {
        if (item?.EntryId is { } id) await _playback.PlayEntryAsync(id);
    }

    public void Dispose() => _timer.Stop();
}

public sealed record UpNextItem(Track Track, string? ArtworkPath, Guid EntryId)
{
    public string Title => Track.DisplayTitle;
    public string Artist => Track.DisplayArtist;
}
