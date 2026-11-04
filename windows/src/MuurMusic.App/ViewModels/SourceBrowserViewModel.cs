using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using Microsoft.Extensions.DependencyInjection;
using CommunityToolkit.Mvvm.Input;
using MuurMusic.App.Services;
using MuurMusic.Audio.Playback;
using MuurMusic.Core.Downloads;
using MuurMusic.Core.Models;
using MuurMusic.Core.Sources;

namespace MuurMusic.App.ViewModels;

public sealed partial class BrowserItemViewModel : ObservableObject
{
    public required SourceItem Item { get; init; }
    public required IMusicSource Source { get; init; }

    public string Name => Item.Name;
    public bool IsFolder => Item.IsFolder;
    public bool IsPlayable => Item.IsPlayable;
    public string Glyph => Item.Kind switch
    {
        SourceItemKind.Folder => "\uE8B7",
        SourceItemKind.Audio => "\uE8D6",
        SourceItemKind.Playlist => "\uE8FD",
        SourceItemKind.Artist => "\uE77B",
        SourceItemKind.Album => "\uE93C",
        _ => "\uE7C3",
    };
    public string Subtitle => Item.Subtitle
        ?? (Item.Size is { } size && !IsFolder ? Services.Formatters.Bytes(size) : "")
        ?? "";
}

/// <summary>Folder-by-folder browser for any connected source.</summary>
public sealed partial class SourceBrowserViewModel : ObservableObject
{
    private readonly ISourceManager _sources;
    private readonly IPlaybackService _playback;
    private readonly IDownloadManager _downloads;
    private readonly NotificationService _notifications;
    private readonly Stack<string> _back = new();
    private IMusicSource? _source;

    public SourceBrowserViewModel(ISourceManager sources, IPlaybackService playback, IDownloadManager downloads, NotificationService notifications)
    {
        _sources = sources;
        _playback = playback;
        _downloads = downloads;
        _notifications = notifications;
    }

    public ObservableCollection<BrowserItemViewModel> Items { get; } = new();
    [ObservableProperty] private string _sourceName = "Source";
    [ObservableProperty] private string _currentUri = "";
    [ObservableProperty] private string _currentFolderName = "Root";
    [ObservableProperty] private bool _canGoUp;
    [ObservableProperty] private bool _isLoading;
    [ObservableProperty] private bool _isEmpty;
    [ObservableProperty] private string _error = "";
    [ObservableProperty] private bool _offlineMode;

    public bool ShowEmpty => !IsLoading && IsEmpty && !HasError;
    public bool HasError => Error.Length > 0;
    public string EmptyText => OfflineMode
        ? "Nothing cached from here yet. Turn offline mode off to browse live."
        : "This folder is empty.";
    partial void OnIsLoadingChanged(bool value) => OnPropertyChanged(nameof(ShowEmpty));
    partial void OnIsEmptyChanged(bool value) => OnPropertyChanged(nameof(ShowEmpty));
    partial void OnErrorChanged(string value)
    {
        OnPropertyChanged(nameof(HasError));
        OnPropertyChanged(nameof(ShowEmpty));
    }

    public async Task LoadAsync(Guid sourceId)
    {
        _source = _sources.Get(sourceId);
        if (_source is null) { Error = "This source no longer exists."; return; }
        SourceName = _source.Config.Name;
        OfflineMode = App.Services.GetRequiredService<MuurMusic.Core.Settings.ISettingsService>().Current.OfflineMode;
        await ShowFolderAsync(null);
    }

    private async Task ShowFolderAsync(string? uri)
    {
        if (_source is null) return;
        IsLoading = true;
        Error = "";
        try
        {
            var items = await _source.ListAsync(uri);
            Items.Clear();
            foreach (var item in items
                         .OrderByDescending(i => i.IsFolder)
                         .ThenBy(i => i.Name, StringComparer.CurrentCultureIgnoreCase))
                Items.Add(new BrowserItemViewModel { Item = item, Source = _source });
            CurrentUri = uri ?? "";
            CurrentFolderName = uri is null ? "Root" : items.FirstOrDefault()?.Name is { Length: > 0 } n && uri == CurrentUri ? n : UriName(uri);
            CanGoUp = _back.Count > 0;
            IsEmpty = Items.Count == 0;
        }
        catch (OfflineException)
        {
            Error = "Offline mode is on. Turn it off in Settings to reach this source.";
        }
        catch (Exception ex)
        {
            Error = ex.Message;
        }
        finally
        {
            IsLoading = false;
        }
    }

    private static string UriName(string uri)
    {
        var trimmed = uri.TrimEnd('/');
        var idx = trimmed.LastIndexOf('/');
        return idx >= 0 && idx < trimmed.Length - 1 ? Uri.UnescapeDataString(trimmed[(idx + 1)..]) : uri;
    }

    public async Task OpenAsync(BrowserItemViewModel? item)
    {
        if (item is null || _source is null) return;
        if (!item.IsFolder) { await PlayAsync(item); return; }
        _back.Push(CurrentUri);
        CurrentFolderName = item.Name;
        await ShowFolderAsync(item.Item.Uri);
        CurrentFolderName = item.Name;
        CanGoUp = _back.Count > 0;
    }

    [RelayCommand]
    private async Task GoUp()
    {
        if (_back.Count == 0) return;
        var uri = _back.Pop();
        CurrentFolderName = uri.Length == 0 ? "Root" : UriName(uri);
        await ShowFolderAsync(uri.Length == 0 ? null : uri);
        CurrentFolderName = uri.Length == 0 ? "Root" : UriName(uri);
        CanGoUp = _back.Count > 0;
    }

    [RelayCommand]
    private async Task Refresh() => await ShowFolderAsync(CurrentUri.Length == 0 ? null : CurrentUri);

    private async Task<Track?> ResolveTrackAsync(BrowserItemViewModel item)
    {
        if (item.Item.Track is { } t) return t;
        if (_source is null) return null;
        return await _source.GetTrackAsync(item.Item.Uri);
    }

    public async Task PlayAsync(BrowserItemViewModel? item)
    {
        if (item is null) return;
        var track = await ResolveTrackAsync(item);
        if (track is null)
        {
            _notifications.Warning("Cannot play", "This item does not resolve to a playable track.");
            return;
        }
        // Play all playable siblings starting at this one.
        var siblings = new List<Track>();
        var startIndex = 0;
        foreach (var sibling in Items.Where(i => i.IsPlayable))
        {
            var t = await ResolveTrackAsync(sibling);
            if (t is null) continue;
            if (sibling == item) startIndex = siblings.Count;
            siblings.Add(t);
        }
        if (siblings.Count == 0) siblings.Add(track);
        await _playback.PlayAsync(siblings, startIndex);
    }

    [RelayCommand]
    private async Task PlayAll()
    {
        var tracks = new List<Track>();
        foreach (var item in Items.Where(i => i.IsPlayable))
            if (await ResolveTrackAsync(item) is { } t) tracks.Add(t);
        if (tracks.Count == 0)
        {
            _notifications.Warning("Nothing to play", "This folder has no playable items.");
            return;
        }
        await _playback.PlayAsync(tracks, 0);
    }

    public async Task EnqueueAsync(BrowserItemViewModel? item, bool next)
    {
        if (item is null || await ResolveTrackAsync(item) is not { } track) return;
        if (next) _playback.EnqueueNext(new[] { track }); else _playback.EnqueueLast(new[] { track });
    }

    public async Task DownloadAsync(BrowserItemViewModel? item)
    {
        if (item is null) return;
        if (await ResolveTrackAsync(item) is { } track)
        {
            await _downloads.MakeAvailableOfflineAsync(new[] { track });
            _notifications.Success("Downloading", $"{item.Name} queued for offline listening.");
        }
        else
        {
            var dl = await _downloads.DownloadUriAsync(item.Item.Uri, item.Name);
            _notifications.Success("Downloading", dl.Title);
        }
    }
}
