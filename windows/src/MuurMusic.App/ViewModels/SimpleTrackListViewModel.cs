using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using MuurMusic.App.Services;
using MuurMusic.Audio.Playback;
using MuurMusic.Core.Data;
using MuurMusic.Core.Models;

namespace MuurMusic.App.ViewModels;

/// <summary>History / recently added / most played / favorites list pages.</summary>
public sealed partial class SimpleTrackListViewModel : ObservableObject
{
    private readonly ITrackRepository _tracks;
    private readonly IPlaybackService _playback;

    public SimpleTrackListViewModel(ITrackRepository tracks, IPlaybackService playback)
    {
        _tracks = tracks;
        _playback = playback;
    }

    public ObservableCollection<Track> Tracks { get; } = new();
    public ObservableCollection<PlayHistoryEntry> HistoryEntries { get; } = new();
    [ObservableProperty] private string _title = "";
    [ObservableProperty] private string _subtitle = "";
    [ObservableProperty] private bool _isHistory;
    [ObservableProperty] private bool _isLoading = true;
    [ObservableProperty] private bool _isEmpty;

    public bool ShowEmpty => IsEmpty && !IsLoading;
    partial void OnIsLoadingChanged(bool value) => OnPropertyChanged(nameof(ShowEmpty));
    partial void OnIsEmptyChanged(bool value) => OnPropertyChanged(nameof(ShowEmpty));

    public async Task LoadAsync(string kind)
    {
        IsLoading = true;
        IsHistory = kind == "history";
        switch (kind)
        {
            case "history":
                Title = "Listening history";
                HistoryEntries.Clear();
                foreach (var h in await _tracks.GetHistoryAsync(200)) HistoryEntries.Add(h);
                IsEmpty = HistoryEntries.Count == 0;
                Subtitle = $"{HistoryEntries.Count} plays";
                break;
            case "recent":
                Title = "Recently added";
                await Fill(await _tracks.GetRecentlyAddedAsync(200));
                break;
            case "mostplayed":
                Title = "Most played";
                await Fill(await _tracks.GetMostPlayedAsync(200));
                break;
            case "favorites":
                Title = "Favorites";
                await Fill(await _tracks.GetFavoritesAsync());
                break;
        }
        IsLoading = false;

        async Task Fill(IReadOnlyList<Track> tracks)
        {
            Tracks.Clear();
            foreach (var t in tracks) Tracks.Add(t);
            IsEmpty = Tracks.Count == 0;
            Subtitle = $"{Tracks.Count} tracks";
        }
    }

    public Task PlayAsync(Track? startAt)
    {
        if (Tracks.Count == 0) return Task.CompletedTask;
        var idx = 0;
        if (startAt is not null)
            for (var i = 0; i < Tracks.Count; i++)
                if (Tracks[i].Key == startAt.Key) { idx = i; break; }
        return _playback.PlayAsync(Tracks.ToList(), idx);
    }

    public async Task PlayHistoryAsync(PlayHistoryEntry? entry)
    {
        if (entry is null) return;
        var track = await _tracks.GetBySourceUriAsync(entry.SourceUri);
        if (track is not null) await _playback.PlayAsync(new[] { track }, 0);
    }

    [RelayCommand]
    private async Task ClearHistory()
    {
        await _tracks.ClearHistoryAsync();
        HistoryEntries.Clear();
        IsEmpty = true;
        Subtitle = "0 plays";
    }
}
