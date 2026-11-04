using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Dispatching;
using MuurMusic.App.Services;
using MuurMusic.Audio.Playback;
using MuurMusic.Core.Data;
using MuurMusic.Core.Library;
using MuurMusic.Core.Models;
using MuurMusic.Core.Settings;
using MuurMusic.Core.Tags;

namespace MuurMusic.App.ViewModels;

public sealed partial class AlbumCardViewModel : ObservableObject
{
    public required Album Album { get; init; }
    public string? ArtworkPath { get; init; }
    public string Name => Album.Name;
    public string Artist => Album.AlbumArtist;
    public string SubText => $"{(Album.Year is { } y ? y + " \u00B7 " : "")}{Album.TrackCount} track{(Album.TrackCount == 1 ? "" : "s")}";
    public bool IsHiRes => Album.IsHiRes;
}

/// <summary>Album artwork grid with sorting and filtering.</summary>
public sealed partial class AlbumsViewModel : ObservableObject
{
    private readonly ITrackRepository _tracks;
    private readonly IArtworkCache _artwork;
    private readonly IPlaybackService _playback;
    private readonly DispatcherQueueTimer _debounce;

    public AlbumsViewModel(ITrackRepository tracks, IArtworkCache artwork, IPlaybackService playback, ILibraryScanner scanner)
    {
        _tracks = tracks;
        _artwork = artwork;
        _playback = playback;
        _debounce = DispatcherQueue.GetForCurrentThread().CreateTimer();
        _debounce.Interval = TimeSpan.FromMilliseconds(700);
        _debounce.IsRepeating = false;
        _debounce.Tick += async (_, _) => await LoadAsync();
        scanner.LibraryChanged += (_, _) => _debounce.Start();
    }

    public ObservableCollection<AlbumCardViewModel> Albums { get; } = new();
    [ObservableProperty] private bool _isLoading = true;
    [ObservableProperty] private bool _isEmpty;
    public bool ShowEmpty => IsEmpty && !IsLoading;
    partial void OnIsLoadingChanged(bool value) => OnPropertyChanged(nameof(ShowEmpty));
    partial void OnIsEmptyChanged(bool value) => OnPropertyChanged(nameof(ShowEmpty));
    [ObservableProperty] private string _filter = "";
    [ObservableProperty] private AlbumSortField _sortField = AlbumSortField.Name;

    public async Task LoadAsync()
    {
        IsLoading = true;
        var albums = await _tracks.GetAlbumsAsync(new AlbumQuery
        {
            Search = string.IsNullOrWhiteSpace(Filter) ? null : Filter.Trim(),
            Sort = SortField,
            Descending = SortField is AlbumSortField.DateAdded or AlbumSortField.PlayCount or AlbumSortField.Year,
        });
        Albums.Clear();
        foreach (var a in albums)
            Albums.Add(new AlbumCardViewModel { Album = a, ArtworkPath = _artwork.GetThumbnailPath(a.ArtworkHash, 256) });
        IsEmpty = Albums.Count == 0;
        IsLoading = false;
    }

    [RelayCommand]
    private async Task SortBy(string field)
    {
        if (Enum.TryParse<AlbumSortField>(field, out var f)) { SortField = f; await LoadAsync(); }
    }

    partial void OnFilterChanged(string value) => _ = LoadAsync();

    public Task PlayAlbumAsync(AlbumCardViewModel? card, bool shuffle = false) => PlayAlbumKeyAsync(card?.Album.Key, shuffle);

    public async Task PlayAlbumKeyAsync(string? albumKey, bool shuffle)
    {
        if (albumKey is null) return;
        var tracks = await _tracks.GetAlbumTracksAsync(albumKey);
        if (tracks.Count == 0) return;
        await _playback.PlayAsync(tracks, 0);
        _playback.Shuffle = shuffle;
    }

    public async Task EnqueueAlbumAsync(AlbumCardViewModel? card, bool next)
    {
        if (card is null) return;
        var tracks = await _tracks.GetAlbumTracksAsync(card.Album.Key);
        if (next) _playback.EnqueueNext(tracks); else _playback.EnqueueLast(tracks);
    }
}

public sealed partial class ArtistCardViewModel : ObservableObject
{
    public required Artist Artist { get; init; }
    public string? ArtworkPath { get; init; }
    public string Name => Artist.Name;
    public string SubText => $"{Artist.AlbumCount} album{(Artist.AlbumCount == 1 ? "" : "s")} \u00B7 {Artist.TrackCount} track{(Artist.TrackCount == 1 ? "" : "s")}";
    public string Initials => string.Concat(Artist.Name.Split(' ', StringSplitOptions.RemoveEmptyEntries).Take(2).Select(w => char.ToUpperInvariant(w[0])));
}

/// <summary>Artists or album artists artwork grid.</summary>
public sealed partial class ArtistsViewModel : ObservableObject
{
    private readonly ITrackRepository _tracks;
    private readonly IArtworkCache _artwork;
    private readonly DispatcherQueueTimer _debounce;

    public ArtistsViewModel(ITrackRepository tracks, IArtworkCache artwork, ILibraryScanner scanner)
    {
        _tracks = tracks;
        _artwork = artwork;
        _debounce = DispatcherQueue.GetForCurrentThread().CreateTimer();
        _debounce.Interval = TimeSpan.FromMilliseconds(700);
        _debounce.IsRepeating = false;
        _debounce.Tick += async (_, _) => await LoadAsync();
        scanner.LibraryChanged += (_, _) => _debounce.Start();
    }

    public bool AlbumArtists { get; set; }

    public ObservableCollection<ArtistCardViewModel> Artists { get; } = new();
    [ObservableProperty] private bool _isLoading = true;
    [ObservableProperty] private bool _isEmpty;
    public bool ShowEmpty => IsEmpty && !IsLoading;
    partial void OnIsLoadingChanged(bool value) => OnPropertyChanged(nameof(ShowEmpty));
    partial void OnIsEmptyChanged(bool value) => OnPropertyChanged(nameof(ShowEmpty));
    [ObservableProperty] private string _filter = "";

    public async Task LoadAsync()
    {
        IsLoading = true;
        var artists = await _tracks.GetArtistsAsync(AlbumArtists, string.IsNullOrWhiteSpace(Filter) ? null : Filter.Trim());
        Artists.Clear();
        foreach (var a in artists)
            Artists.Add(new ArtistCardViewModel { Artist = a, ArtworkPath = _artwork.GetThumbnailPath(a.ArtworkHash, 256) });
        IsEmpty = Artists.Count == 0;
        IsLoading = false;
    }

    partial void OnFilterChanged(string value) => _ = LoadAsync();
}

public sealed record NameCountItem(string Name, int AlbumCount, int TrackCount)
{
    public string SubText => $"{AlbumCount} album{(AlbumCount == 1 ? "" : "s")} \u00B7 {TrackCount} track{(TrackCount == 1 ? "" : "s")}";
}

/// <summary>Genre / composer lists (click through to their tracks).</summary>
public sealed partial class GenresViewModel : ObservableObject
{
    private readonly ITrackRepository _tracks;
    private readonly DispatcherQueueTimer _debounce;

    public GenresViewModel(ITrackRepository tracks, ILibraryScanner scanner)
    {
        _tracks = tracks;
        _debounce = DispatcherQueue.GetForCurrentThread().CreateTimer();
        _debounce.Interval = TimeSpan.FromMilliseconds(700);
        _debounce.IsRepeating = false;
        _debounce.Tick += async (_, _) => await LoadAsync();
        scanner.LibraryChanged += (_, _) => _debounce.Start();
    }

    public bool Composers { get; set; }

    public ObservableCollection<NameCountItem> Items { get; } = new();
    [ObservableProperty] private bool _isLoading = true;
    [ObservableProperty] private bool _isEmpty;
    public bool ShowEmpty => IsEmpty && !IsLoading;
    partial void OnIsLoadingChanged(bool value) => OnPropertyChanged(nameof(ShowEmpty));
    partial void OnIsEmptyChanged(bool value) => OnPropertyChanged(nameof(ShowEmpty));

    public async Task LoadAsync()
    {
        IsLoading = true;
        if (Composers)
        {
            var list = await _tracks.GetComposersAsync();
            Items.Clear();
            foreach (var c in list) Items.Add(new NameCountItem(c.Name, c.AlbumCount, c.TrackCount));
        }
        else
        {
            var list = await _tracks.GetGenresAsync();
            Items.Clear();
            foreach (var g in list) Items.Add(new NameCountItem(g.Name, g.AlbumCount, g.TrackCount));
        }
        IsEmpty = Items.Count == 0;
        IsLoading = false;
    }
}

/// <summary>Library folder browser (watched folders, one level at a time).</summary>
public sealed partial class FoldersViewModel : ObservableObject
{
    private readonly ITrackRepository _tracks;
    private readonly ISettingsService _settings;
    private readonly IArtworkCache _artwork;
    private readonly IPlaybackService _playback;
    private readonly Stack<string> _back = new();
    private readonly DispatcherQueueTimer _debounce;

    public FoldersViewModel(ITrackRepository tracks, ISettingsService settings, IArtworkCache artwork, IPlaybackService playback, ILibraryScanner scanner)
    {
        _tracks = tracks;
        _settings = settings;
        _artwork = artwork;
        _playback = playback;
        _debounce = DispatcherQueue.GetForCurrentThread().CreateTimer();
        _debounce.Interval = TimeSpan.FromMilliseconds(700);
        _debounce.IsRepeating = false;
        _debounce.Tick += async (_, _) => await ReloadAsync();
        scanner.LibraryChanged += (_, _) => _debounce.Start();
    }

    public ObservableCollection<FolderCardItem> Folders { get; } = new();
    public ObservableCollection<Track> Tracks { get; } = new();
    [ObservableProperty] private string _currentPath = "";
    [ObservableProperty] private string _title = "Folders";
    [ObservableProperty] private bool _canGoUp;
    [ObservableProperty] private bool _isEmpty;
    public bool HasFolders => Folders.Count > 0;

    /// <summary>Raised from pages after bulk folder/track changes (ObservableCollection lacks a reset here).</summary>
    public void NotifyFoldersChanged()
    {
        OnPropertyChanged(nameof(HasFolders));
        OnPropertyChanged(nameof(IsEmpty));
    }

    public async Task LoadRootsAsync()
    {
        _back.Clear();
        Folders.Clear();
        Tracks.Clear();
        var roots = await _tracks.GetRootFoldersAsync(_settings.Current.WatchedFolders);
        foreach (var f in roots)
            Folders.Add(new FolderCardItem(f.Path, f.Name, f.TrackCount, _artwork.FindFolderImage(f.Path)));
        Title = "Folders";
        CurrentPath = "";
        CanGoUp = false;
        IsEmpty = Folders.Count == 0;
    }

    public async Task OpenFolderAsync(string path)
    {
        _back.Push(CurrentPath); // "" marks the roots level
        await ShowFolderAsync(path);
    }

    private async Task ShowFolderAsync(string path)
    {
        var contents = await _tracks.GetFolderContentsAsync(path, TrackSortField.FileName);
        Folders.Clear();
        foreach (var f in contents.Folders)
            Folders.Add(new FolderCardItem(f.Path, f.Name, f.TrackCount, _artwork.FindFolderImage(f.Path)));
        Tracks.Clear();
        foreach (var t in contents.Tracks) Tracks.Add(t);
        CurrentPath = path;
        Title = Path.GetFileName(path.TrimEnd('\\')) is { Length: > 0 } n ? n : path;
        CanGoUp = true;
        IsEmpty = Folders.Count == 0 && Tracks.Count == 0;
    }

    public async Task ReloadAsync()
    {
        if (string.IsNullOrEmpty(CurrentPath)) await LoadRootsAsync();
        else await ShowFolderAsync(CurrentPath);
    }

    [RelayCommand]
    private async Task GoUp()
    {
        if (_back.Count == 0) { await LoadRootsAsync(); return; }
        var target = _back.Pop();
        if (target.Length == 0) { await LoadRootsAsync(); return; }
        await ShowFolderAsync(target);
        CanGoUp = true; // the roots level is always one more “Up” away
    }

    public Task PlayTracksAsync(IReadOnlyList<Track> tracks, Track? startAt) =>
        tracks.Count == 0 ? Task.CompletedTask : _playback.PlayAsync(tracks, StartIndex(tracks, startAt));

    [RelayCommand]
    private Task PlayFolder() => PlayTracksAsync(Tracks.ToList(), null);

    [RelayCommand]
    private void EnqueueFolder(bool next)
    {
        if (next) _playback.EnqueueNext(Tracks); else _playback.EnqueueLast(Tracks);
    }

    private static int StartIndex(IReadOnlyList<Track> tracks, Track? startAt)
    {
        if (startAt is null) return 0;
        for (var i = 0; i < tracks.Count; i++) if (tracks[i].Key == startAt.Key) return i;
        return 0;
    }
}

public sealed record FolderCardItem(string Path, string Name, int TrackCount, string? ImagePath)
{
    public string SubText => $"{TrackCount} track{(TrackCount == 1 ? "" : "s")}";
    public string Initials => string.Concat(Name.Split(' ', StringSplitOptions.RemoveEmptyEntries).Take(2).Select(w => char.ToUpperInvariant(w[0])));
}
