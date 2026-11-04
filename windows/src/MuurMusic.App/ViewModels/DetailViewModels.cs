using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using Microsoft.Extensions.DependencyInjection;
using CommunityToolkit.Mvvm.Input;
using MuurMusic.App.Services;
using MuurMusic.Audio.Playback;
using MuurMusic.Core.Data;
using MuurMusic.Core.Models;
using MuurMusic.Core.Tags;

namespace MuurMusic.App.ViewModels;

/// <summary>Album detail: artwork header + ordered track list.</summary>
public sealed partial class AlbumDetailViewModel : ObservableObject
{
    private readonly ITrackRepository _tracks;
    private readonly IArtworkCache _artwork;
    private readonly IPlaybackService _playback;
    private readonly NotificationService _notifications;

    public AlbumDetailViewModel(ITrackRepository tracks, IArtworkCache artwork, IPlaybackService playback, NotificationService notifications)
    {
        _tracks = tracks;
        _artwork = artwork;
        _playback = playback;
        _notifications = notifications;
    }

    public ObservableCollection<Track> Tracks { get; } = new();
    [ObservableProperty] private string _title = "Album";
    [ObservableProperty] private string _artist = "";
    [ObservableProperty] private string _subtitle = "";
    [ObservableProperty] private string? _artworkPath;
    [ObservableProperty] private bool _isHiRes;
    [ObservableProperty] private string _qualityBadges = "";

    public async Task LoadAsync(string albumKey)
    {
        var album = await _tracks.GetAlbumAsync(albumKey);
        var tracks = await _tracks.GetAlbumTracksAsync(albumKey);
        Tracks.Clear();
        foreach (var t in tracks) Tracks.Add(t);
        if (album is not null)
        {
            Title = album.Name;
            Artist = album.AlbumArtist;
            IsHiRes = album.IsHiRes;
            ArtworkPath = _artwork.GetPath(album.ArtworkHash) ?? _artwork.GetThumbnailPath(album.ArtworkHash, 512);
            var duration = TimeSpan.FromMilliseconds(album.DurationMs);
            Subtitle = $"{(album.Year is { } y ? y + " \u00B7 " : "")}{album.TrackCount} tracks \u00B7 {(int)duration.TotalMinutes} min";
            QualityBadges = album.Codec ?? "";
        }
        else if (Tracks.Count > 0)
        {
            Title = Tracks[0].DisplayAlbum;
            Artist = Tracks[0].DisplayArtist;
            ArtworkPath = _artwork.GetPath(Tracks[0].ArtworkHash);
            Subtitle = $"{Tracks.Count} tracks";
        }
    }

    public Task PlayAsync(Track? startAt, bool shuffle = false)
    {
        if (Tracks.Count == 0) return Task.CompletedTask;
        var idx = 0;
        if (startAt is not null)
            for (var i = 0; i < Tracks.Count; i++)
                if (Tracks[i].Key == startAt.Key) { idx = i; break; }
        _playback.Shuffle = shuffle;
        return _playback.PlayAsync(Tracks.ToList(), idx);
    }

    [RelayCommand]
    private void Enqueue(bool next)
    {
        if (next) _playback.EnqueueNext(Tracks); else _playback.EnqueueLast(Tracks);
    }

    [RelayCommand]
    private async Task Download()
    {
        var dm = App.Services.GetRequiredService<MuurMusic.Core.Downloads.IDownloadManager>();
        await dm.MakeAvailableOfflineAsync(Tracks.ToList());
        _notifications.Success("Downloading", $"{Title} queued for offline listening.");
    }
}

/// <summary>Artist detail: albums by this artist + all tracks.</summary>
public sealed partial class ArtistDetailViewModel : ObservableObject
{
    private readonly ITrackRepository _tracks;
    private readonly IArtworkCache _artwork;
    private readonly IPlaybackService _playback;

    public ArtistDetailViewModel(ITrackRepository tracks, IArtworkCache artwork, IPlaybackService playback)
    {
        _tracks = tracks;
        _artwork = artwork;
        _playback = playback;
    }

    public ObservableCollection<AlbumCardViewModel> Albums { get; } = new();
    public ObservableCollection<Track> Tracks { get; } = new();
    [ObservableProperty] private string _name = "Artist";
    [ObservableProperty] private string? _artworkPath;
    [ObservableProperty] private string _subtitle = "";
    [ObservableProperty] private bool _hasAlbums;

    public async Task LoadAsync(ArtistNavigation nav)
    {
        Name = nav.Name;
        // AlbumQuery.Artist matches album artist or track artist; track-side narrows per page kind.
        var albums = await _tracks.GetAlbumsAsync(new AlbumQuery { Artist = nav.Name, Sort = AlbumSortField.Year });
        Albums.Clear();
        foreach (var a in albums)
            Albums.Add(new AlbumCardViewModel { Album = a, ArtworkPath = _artwork.GetThumbnailPath(a.ArtworkHash, 256) });
        HasAlbums = Albums.Count > 0;

        var trackQuery = nav.AlbumArtists
            ? new TrackQuery { AlbumArtist = nav.Name }
            : new TrackQuery { Artist = nav.Name };
        var tracks = await _tracks.QueryAsync(trackQuery with { Sort = TrackSortField.Album });
        Tracks.Clear();
        foreach (var t in tracks) Tracks.Add(t);

        ArtworkPath = albums.FirstOrDefault() is { } first ? _artwork.GetThumbnailPath(first.ArtworkHash, 512) : null;
        var duration = TimeSpan.FromMilliseconds(tracks.Sum(t => t.DurationMs));
        Subtitle = $"{albums.Count} album{(albums.Count == 1 ? "" : "s")} \u00B7 {tracks.Count} tracks \u00B7 {(int)duration.TotalHours} hr {duration.Minutes} min";
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

    [RelayCommand]
    private async Task ShufflePlay()
    {
        if (Tracks.Count == 0) return;
        await _playback.PlayAsync(Tracks.ToList(), 0);
        _playback.Shuffle = true;
    }
}

/// <summary>Generic filtered track list (genres/composers/search results context).</summary>
public sealed partial class TrackListViewModel : ObservableObject
{
    private readonly ITrackRepository _tracks;
    private readonly IPlaybackService _playback;

    public TrackListViewModel(ITrackRepository tracks, IPlaybackService playback)
    {
        _tracks = tracks;
        _playback = playback;
    }

    public ObservableCollection<Track> Tracks { get; } = new();
    [ObservableProperty] private string _title = "Tracks";
    [ObservableProperty] private string _subtitle = "";

    public async Task LoadAsync(TrackListNavigation nav)
    {
        Title = nav.Title;
        var tracks = await _tracks.QueryAsync(nav.Query);
        Tracks.Clear();
        foreach (var t in tracks) Tracks.Add(t);
        Subtitle = $"{Tracks.Count} tracks";
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
}
