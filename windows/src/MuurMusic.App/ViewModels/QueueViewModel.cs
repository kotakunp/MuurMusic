using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using MuurMusic.App.Services;
using MuurMusic.Audio.Playback;
using MuurMusic.Core.Data;
using MuurMusic.Core.Models;

namespace MuurMusic.App.ViewModels;

/// <summary>One row in the queue flyout.</summary>
public sealed partial class QueueEntryItemViewModel : ObservableObject
{
    public required QueueEntry Entry { get; init; }
    [ObservableProperty] private bool _isCurrent;
    public Guid EntryId => Entry.EntryId;
    public Track Track => Entry.Track;
    public string Title => Track.DisplayTitle;
    public string Artist => Track.DisplayArtist;
    public string Duration => Track.Duration.TotalHours >= 1
        ? $"{(int)Track.Duration.TotalHours}:{Track.Duration.Minutes:00}:{Track.Duration.Seconds:00}"
        : $"{Track.Duration.Minutes}:{Track.Duration.Seconds:00}";
    public string QualityBadge => Track.QualityBadge;
    public Windows.UI.Text.FontWeight TitleWeight => IsCurrent ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal;

    partial void OnIsCurrentChanged(bool value) => OnPropertyChanged(nameof(TitleWeight));
}

/// <summary>
/// The play queue shown in the transport bar flyout: reorder (drag), remove, play-from-here,
/// save-as-playlist and clear. All mutations go through <see cref="IPlaybackService"/>.
/// </summary>
public sealed partial class QueueViewModel : ObservableObject
{
    private readonly IPlaybackService _playback;
    private readonly NotificationService _notifications;
    private readonly IPlaylistRepository _playlists;
    private bool _reordering;

    public QueueViewModel(IPlaybackService playback, NotificationService notifications, IPlaylistRepository playlists)
    {
        _playback = playback;
        _notifications = notifications;
        _playlists = playlists;
        playback.QueueChanged += (_, _) => { if (!_reordering) Rebuild(); };
        playback.TrackChanged += (_, _) => UpdateCurrent();
        Rebuild();
    }

    public ObservableCollection<QueueEntryItemViewModel> Items { get; } = new();

    [ObservableProperty] private string _summary = "Queue is empty";
    [ObservableProperty] private bool _isEmpty = true;

    private void Rebuild()
    {
        var current = _playback.CurrentEntryId;
        Items.Clear();
        foreach (var e in _playback.Queue.Items)
            Items.Add(new QueueEntryItemViewModel { Entry = e, IsCurrent = e.EntryId == current });
        UpdateSummary();
    }

    private void UpdateCurrent()
    {
        var current = _playback.CurrentEntryId;
        foreach (var item in Items) item.IsCurrent = item.EntryId == current;
    }

    private void UpdateSummary()
    {
        var q = _playback.Queue;
        IsEmpty = q.Count == 0;
        var total = TimeSpan.FromMilliseconds(q.Items.Sum(i => i.Track.DurationMs));
        Summary = q.Count == 0
            ? "Queue is empty"
            : $"{q.Count} track{(q.Count == 1 ? "" : "s")} \u00B7 {(total.TotalHours >= 1 ? $"{(int)total.TotalHours} hr {total.Minutes} min" : $"{(int)total.TotalMinutes} min")}";
    }

    /// <summary>Called by the view while a drag reorder is in flight; the service is the source of truth.</summary>
    public void BeginReorder() => _reordering = true;

    public void EndReorder(int fromIndex, int toIndex)
    {
        _reordering = false;
        if (fromIndex != toIndex && fromIndex >= 0 && toIndex >= 0 && fromIndex < Items.Count && toIndex < Items.Count)
            _playback.MoveQueueEntry(fromIndex, toIndex);
        Rebuild();
    }

    [RelayCommand]
    private Task PlayEntry(QueueEntryItemViewModel? item) =>
        item is null ? Task.CompletedTask : _playback.PlayEntryAsync(item.EntryId);

    [RelayCommand]
    private async Task RemoveEntry(QueueEntryItemViewModel? item)
    {
        if (item is null) return;
        await _playback.RemoveFromQueueAsync(new[] { item.EntryId });
    }

    [RelayCommand]
    private async Task ClearQueue()
    {
        await _playback.ClearQueueAsync();
        _notifications.Info("Queue cleared");
    }

    [RelayCommand]
    private async Task SaveAsPlaylist(string? name)
    {
        if (string.IsNullOrWhiteSpace(name) || Items.Count == 0) return;
        var playlist = await _playlists.CreateAsync(name.Trim());
        await _playlists.AddTracksAsync(playlist.Id, _playback.Queue.Items.Select(i => i.Track));
        _notifications.Success("Playlist saved", $"\u201C{name.Trim()}\u201D now holds {Items.Count} tracks.");
    }
}
