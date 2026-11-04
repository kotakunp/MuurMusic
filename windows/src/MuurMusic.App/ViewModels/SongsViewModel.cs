using System.Collections.ObjectModel;
using System.Diagnostics;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Dispatching;
using MuurMusic.App.Services;
using MuurMusic.Audio.Playback;
using MuurMusic.Core.Data;
using MuurMusic.Core.Downloads;
using MuurMusic.Core.Library;
using MuurMusic.Core.Models;
using MuurMusic.Core.Settings;

namespace MuurMusic.App.ViewModels;

/// <summary>The Songs library view: sortable track table with playback, rating, favorites, downloads and rescans.</summary>
public sealed partial class SongsViewModel : ObservableObject
{
    private readonly ITrackRepository _tracks;
    private readonly ILibraryScanner _scanner;
    private readonly IPlaybackService _playback;
    private readonly IDownloadManager _downloads;
    private readonly NotificationService _notifications;
    private readonly DispatcherQueueTimer _reloadDebounce;

    public SongsViewModel(ITrackRepository tracks, ILibraryScanner scanner, IPlaybackService playback,
        IDownloadManager downloads, NotificationService notifications)
    {
        _tracks = tracks;
        _scanner = scanner;
        _playback = playback;
        _downloads = downloads;
        _notifications = notifications;

        _reloadDebounce = DispatcherQueue.GetForCurrentThread().CreateTimer();
        _reloadDebounce.Interval = TimeSpan.FromMilliseconds(700);
        _reloadDebounce.IsRepeating = false;
        _reloadDebounce.Tick += async (_, _) => await LoadAsync();

        scanner.LibraryChanged += (_, _) => _reloadDebounce.Start();
        scanner.Progress += (_, p) => UpdateProgress(p);
        scanner.ScanCompleted += (_, r) => OnScanCompleted(r);
    }

    public ObservableCollection<Track> Tracks { get; } = new();

    [ObservableProperty] private bool _isLoading = true;
    [ObservableProperty] private bool _isEmpty;
    [ObservableProperty] private string _countText = "";
    [ObservableProperty] private TrackSortField _sortField = TrackSortField.Title;
    [ObservableProperty] private bool _sortDescending;
    [ObservableProperty] private bool _isScanning;
    [ObservableProperty] private string _scanStatus = "";
    [ObservableProperty] private double _scanFraction;

    public TrackQuery CurrentQuery => new() { Sort = SortField, Descending = SortDescending };

    public async Task LoadAsync()
    {
        IsLoading = true;
        try
        {
            var query = CurrentQuery;
            var list = await _tracks.QueryAsync(query);
            Tracks.Clear();
            foreach (var t in list) Tracks.Add(t);
            IsEmpty = Tracks.Count == 0;
            CountText = Tracks.Count == 0 ? "" : $"{Tracks.Count:N0} song{(Tracks.Count == 1 ? "" : "s")}";
        }
        catch (Exception ex)
        {
            _notifications.Error("Library error", ex.Message);
        }
        finally
        {
            IsLoading = false;
        }
    }

    [RelayCommand]
    private async Task SortBy(string field)
    {
        if (!Enum.TryParse<TrackSortField>(field, out var f)) return;
        if (SortField == f) SortDescending = !SortDescending;
        else { SortField = f; SortDescending = f is TrackSortField.DateAdded or TrackSortField.LastPlayed or TrackSortField.PlayCount; }
        await LoadAsync();
    }

    // ------------------------------------------------ playback actions

    public Task PlayTracksAsync(IReadOnlyList<Track> tracks, Track? startAt)
    {
        if (tracks.Count == 0) return Task.CompletedTask;
        var index = startAt is null ? 0 : Math.Max(0, IndexOfKey(tracks, startAt));
        return _playback.PlayAsync(tracks, index);
    }

    [RelayCommand] private Task Play(Track? track) => track is null ? Task.CompletedTask : PlayTracksAsync(Tracks.ToList(), track);
    [RelayCommand] private Task PlayAll() => PlayTracksAsync(Tracks.ToList(), null);

    [RelayCommand] private void PlayNext(Track? track) { if (track is not null) { _playback.EnqueueNext(new[] { track }); _notifications.Success("Up next", track.DisplayTitle); } }
    [RelayCommand] private void PlayLater(Track? track) { if (track is not null) { _playback.EnqueueLast(new[] { track }); _notifications.Success("Queued", track.DisplayTitle); } }

    public void EnqueueSelectionNext(IEnumerable<Track> selection)
    {
        var list = selection.ToList();
        if (list.Count == 0) return;
        _playback.EnqueueNext(list);
        _notifications.Success("Up next", $"{list.Count} track{(list.Count == 1 ? "" : "s")}");
    }

    public void EnqueueSelectionLast(IEnumerable<Track> selection)
    {
        var list = selection.ToList();
        if (list.Count == 0) return;
        _playback.EnqueueLast(list);
        _notifications.Success("Queued", $"{list.Count} track{(list.Count == 1 ? "" : "s")}");
    }

    // ------------------------------------------------ track actions

    [RelayCommand]
    private async Task ToggleFavorite(Track? track)
    {
        if (track is null || track.Id <= 0) return;
        await _tracks.SetFavoriteAsync(track.Id, !track.Favorite);
        track.Favorite = !track.Favorite;
        RefreshRow(track);
    }

    public async Task SetRatingAsync(IEnumerable<Track> selection, int rating)
    {
        foreach (var t in selection.Where(t => t.Id > 0))
        {
            await _tracks.SetRatingAsync(t.Id, rating);
            t.Rating = rating;
            RefreshRow(t);
        }
    }

    [RelayCommand]
    private void RevealInExplorer(Track? track)
    {
        if (track?.FilePath is { } path && File.Exists(path))
            Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = true });
        else _notifications.Warning("Not a local file", "This track lives on a remote source.");
    }

    [RelayCommand]
    private async Task DownloadOffline(Track? track)
    {
        if (track is null) return;
        await DownloadSelectionAsync(new[] { track });
    }

    public async Task DownloadSelectionAsync(IReadOnlyList<Track> selection)
    {
        if (selection.Count == 0) return;
        try
        {
            var items = await _downloads.MakeAvailableOfflineAsync(selection);
            _notifications.Success("Downloading for offline", $"{items.Count} item{(items.Count == 1 ? "" : "s")} queued.");
        }
        catch (Exception ex)
        {
            _notifications.Error("Download failed", ex.Message);
        }
    }

    [RelayCommand]
    private async Task AddBookmark(Track? track)
    {
        if (track is null) return;
        var current = _playback.CurrentTrack;
        if (current is null || current.Key != track.Key)
        {
            await _playback.PlayAsync(new[] { track });
            _notifications.Info("Playing first", "Bookmark from the player once it reaches the right spot.");
            return;
        }
        var bookmark = await _playback.AddBookmarkAsync();
        _notifications.Success("Bookmark saved", bookmark is null ? null : $"{track.DisplayTitle} at {bookmark.Position:m\\:ss}");
    }

    private void RefreshRow(Track track)
    {
        var i = IndexOfKey(Tracks, track);
        if (i >= 0)
        {
            Tracks.RemoveAt(i);
            Tracks.Insert(i, track);
        }
    }

    private static int IndexOfKey(IReadOnlyList<Track> list, Track track)
    {
        for (var i = 0; i < list.Count; i++)
            if (list[i].Key == track.Key) return i;
        return -1;
    }

    // ------------------------------------------------ scanning

    [RelayCommand]
    private async Task Rescan()
    {
        if (_scanner.IsScanning) return;
        IsScanning = true;
        ScanStatus = "Scanning\u2026";
        ScanFraction = 0;
        try
        {
            await _scanner.ScanAsync();
        }
        catch (Exception ex)
        {
            _notifications.Error("Scan failed", ex.Message);
        }
    }

    [RelayCommand] private void CancelScan() => _scanner.CancelScan();

    private void UpdateProgress(ScanProgress p)
    {
        IsScanning = p.Phase != ScanPhase.Done;
        ScanFraction = p.Fraction;
        ScanStatus = p.Phase switch
        {
            ScanPhase.Enumerating => $"Looking for music\u2026 {p.FilesFound} files",
            ScanPhase.Reading => $"Reading tags\u2026 {p.FilesRead}/{p.FilesToRead}",
            ScanPhase.Saving => "Saving to the library\u2026",
            ScanPhase.Cleaning => "Tidying up\u2026",
            _ => "",
        };
    }

    private void OnScanCompleted(ScanResult r)
    {
        IsScanning = false;
        ScanStatus = "";
        if (r.Added + r.Updated + r.Removed > 0)
            _notifications.Success("Library updated", $"+{r.Added} new, {r.Updated} updated, {r.Removed} removed.");
        else if (!r.Canceled)
            _notifications.Info("Scan finished", "No changes found. Your library is purr-fectly up to date.");
    }
}
