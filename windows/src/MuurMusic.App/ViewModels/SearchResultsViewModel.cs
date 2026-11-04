using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using MuurMusic.Audio.Playback;
using MuurMusic.Core.Data;
using MuurMusic.Core.Models;
using MuurMusic.Core.Playlists;
using MuurMusic.Core.Tags;

namespace MuurMusic.App.ViewModels;

/// <summary>Grouped search results across tracks, albums, artists, playlists and folders.</summary>
public sealed partial class SearchResultsViewModel : ObservableObject
{
    private readonly ITrackRepository _tracks;
    private readonly IPlaylistRepository _playlists;
    private readonly IArtworkCache _artwork;
    private readonly IPlaybackService _playback;

    public SearchResultsViewModel(ITrackRepository tracks, IPlaylistRepository playlists, IArtworkCache artwork, IPlaybackService playback)
    {
        _tracks = tracks;
        _playlists = playlists;
        _artwork = artwork;
        _playback = playback;
    }

    public ObservableCollection<Track> Tracks { get; } = new();
    public ObservableCollection<AlbumCardViewModel> Albums { get; } = new();
    public ObservableCollection<ArtistCardViewModel> Artists { get; } = new();
    public ObservableCollection<PlaylistCardViewModel> Playlists { get; } = new();
    public ObservableCollection<FolderCardItem> Folders { get; } = new();

    [ObservableProperty] private string _query = "";
    [ObservableProperty] private bool _isLoading;
    [ObservableProperty] private bool _hasTracks;
    [ObservableProperty] private bool _hasAlbums;
    [ObservableProperty] private bool _hasArtists;
    [ObservableProperty] private bool _hasPlaylists;
    [ObservableProperty] private bool _hasFolders;

    public bool ShowEmpty => !IsLoading && !HasTracks && !HasAlbums && !HasArtists && !HasPlaylists && !HasFolders;
    private void NotifyGroups()
    {
        OnPropertyChanged(nameof(ShowEmpty));
    }

    public async Task SearchAsync(string query)
    {
        Query = query.Trim();
        Tracks.Clear(); Albums.Clear(); Artists.Clear(); Playlists.Clear(); Folders.Clear();
        HasTracks = HasAlbums = HasArtists = HasPlaylists = HasFolders = false;
        if (Query.Length < 2) { IsLoading = false; NotifyGroups(); return; }
        IsLoading = true;

        var tracks = await _tracks.QueryAsync(new TrackQuery { Search = Query, Limit = 200 });
        foreach (var t in tracks) Tracks.Add(t);
        HasTracks = Tracks.Count > 0;

        var albums = await _tracks.GetAlbumsAsync(new AlbumQuery { Search = Query, Limit = 40 });
        foreach (var a in albums) Albums.Add(new AlbumCardViewModel { Album = a, ArtworkPath = _artwork.GetThumbnailPath(a.ArtworkHash, 256) });
        HasAlbums = Albums.Count > 0;

        var artists = await _tracks.GetArtistsAsync(albumArtists: false, search: Query);
        foreach (var a in artists.Take(24)) Artists.Add(new ArtistCardViewModel { Artist = a, ArtworkPath = _artwork.GetThumbnailPath(a.ArtworkHash, 256) });
        HasArtists = Artists.Count > 0;

        var playlists = await _playlists.GetAllAsync();
        foreach (var p in playlists.Where(p => p.Name.Contains(Query, StringComparison.CurrentCultureIgnoreCase)).Take(12))
            Playlists.Add(new PlaylistCardViewModel { Playlist = p, ArtworkPath = _artwork.GetThumbnailPath(p.ArtworkHash, 256) });
        HasPlaylists = Playlists.Count > 0;

        // Folders containing matches (from the track results).
        foreach (var folder in tracks.Select(t => t.Folder).Where(f => f is { Length: > 0 }).Cast<string>().Distinct(StringComparer.OrdinalIgnoreCase).Take(12))
            Folders.Add(new FolderCardItem(folder, System.IO.Path.GetFileName(folder.TrimEnd('\\')) ?? folder, 0, _artwork.FindFolderImage(folder) ?? ""));
        HasFolders = Folders.Count > 0;
        IsLoading = false;
        NotifyGroups();
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
    private Task PlayAll() => PlayAsync(null);
}
