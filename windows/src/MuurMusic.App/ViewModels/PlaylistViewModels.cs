using System.Collections.ObjectModel;
using System.Text.Json.Nodes;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using MuurMusic.App.Services;
using MuurMusic.Audio.Playback;
using MuurMusic.Core.Data;
using MuurMusic.Core.Models;
using MuurMusic.Core.Playlists;
using MuurMusic.Core.Sources;
using MuurMusic.Core.Tags;

namespace MuurMusic.App.ViewModels;

public sealed partial class PlaylistCardViewModel : ObservableObject
{
    public required Playlist Playlist { get; init; }
    public string? ArtworkPath { get; init; }
    public IReadOnlyList<string?> Collage { get; init; } = Array.Empty<string?>();
    public long Id => Playlist.Id;
    public string Name => Playlist.Name;
    public bool IsSmart => Playlist.IsSmart;
    public string SubText => $"{Playlist.TrackCount} track{(Playlist.TrackCount == 1 ? "" : "s")} \u00B7 {Formatters.Duration(Playlist.DurationMs)}";
}

/// <summary>Playlists grid.</summary>
public sealed partial class PlaylistsViewModel : ObservableObject
{
    private readonly IPlaylistRepository _playlists;
    private readonly IArtworkCache _artwork;
    private readonly NotificationService _notifications;
    private readonly DialogService _dialogs;

    public PlaylistsViewModel(IPlaylistRepository playlists, IArtworkCache artwork, NotificationService notifications, DialogService dialogs)
    {
        _playlists = playlists;
        _artwork = artwork;
        _notifications = notifications;
        _dialogs = dialogs;
    }

    public ObservableCollection<PlaylistCardViewModel> Playlists { get; } = new();
    [ObservableProperty] private bool _isLoading = true;
    [ObservableProperty] private bool _isEmpty;
    public bool ShowEmpty => IsEmpty && !IsLoading;
    partial void OnIsLoadingChanged(bool value) => OnPropertyChanged(nameof(ShowEmpty));
    partial void OnIsEmptyChanged(bool value) => OnPropertyChanged(nameof(ShowEmpty));

    public async Task LoadAsync()
    {
        IsLoading = true;
        var all = await _playlists.GetAllAsync();
        Playlists.Clear();
        foreach (var p in all)
        {
            var collage = new List<string?> { _artwork.GetThumbnailPath(p.ArtworkHash, 256) };
            Playlists.Add(new PlaylistCardViewModel
            {
                Playlist = p,
                ArtworkPath = _artwork.GetThumbnailPath(p.ArtworkHash, 256),
                Collage = collage,
            });
        }
        IsEmpty = Playlists.Count == 0;
        IsLoading = false;
    }

    public async Task<long?> CreateAsync()
    {
        var name = await _dialogs.PromptAsync("New playlist", "Playlist name:");
        if (string.IsNullOrWhiteSpace(name)) return null;
        var playlist = await _playlists.CreateAsync(name.Trim());
        await LoadAsync();
        return playlist.Id;
    }

    public async Task RenameAsync(PlaylistCardViewModel? card)
    {
        if (card is null) return;
        var name = await _dialogs.PromptAsync("Rename playlist", "Name:", card.Name);
        if (string.IsNullOrWhiteSpace(name)) return;
        await _playlists.RenameAsync(card.Id, name.Trim());
        await LoadAsync();
    }

    public async Task DuplicateAsync(PlaylistCardViewModel? card)
    {
        if (card is null) return;
        var copy = await _playlists.DuplicateAsync(card.Id, card.Name + " copy");
        _notifications.Success("Playlist duplicated", copy.Name);
        await LoadAsync();
    }

    public async Task DeleteAsync(PlaylistCardViewModel? card)
    {
        if (card is null) return;
        if (!await _dialogs.ConfirmAsync("Delete playlist", $"Delete \\u201C{card.Name}\\u201D? The tracks stay in your library.", "Delete")) return;
        await _playlists.DeleteAsync(card.Id);
        await LoadAsync();
    }

    public async Task ImportAsync()
    {
        var path = await _dialogs.PickOpenFileAsync("Import", ".m3u", ".m3u8", ".pls", ".cue", ".json");
        if (path is null) return;
        try
        {
            var io = Microsoft.Extensions.DependencyInjection.ServiceProviderServiceExtensions.GetRequiredService<IPlaylistIoService>(App.Services);
            var result = await io.ImportAsync(path);
            _notifications.Success("Playlist imported", $"{result.Playlist.Name}: {result.Imported} tracks{(result.Missing.Count > 0 ? $", {result.Missing.Count} missing" : "")}.");
            await LoadAsync();
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            _notifications.Error("Import failed", ex.Message);
        }
    }
}

public sealed partial class PlaylistEntryItemViewModel : ObservableObject
{
    public required PlaylistEntry Entry { get; init; }
    public string? ArtworkPath { get; init; }
    public string Title => Entry.Track?.DisplayTitle ?? Entry.Title ?? SourceUris.FileNameOf(Entry.SourceUri);
    public string Artist => Entry.Track?.DisplayArtist ?? Entry.Artist ?? "";
    public string DurationText => Formatters.Duration(Entry.Track?.DurationMs ?? Entry.DurationMs);
    public bool IsMissing => Entry.Track is null || Entry.Track.IsUnavailable;
    public int Position => Entry.Position;
    public string PositionDisplay => (Position + 1).ToString();
}

/// <summary>Playlist detail: reorder, remove, play, export; smart playlists show a rules summary.</summary>
public sealed partial class PlaylistDetailViewModel : ObservableObject
{
    private readonly IPlaylistRepository _playlists;
    private readonly IPlaylistIoService _io;
    private readonly IArtworkCache _artwork;
    private readonly IPlaybackService _playback;
    private readonly NotificationService _notifications;
    private readonly DialogService _dialogs;

    public PlaylistDetailViewModel(IPlaylistRepository playlists, IPlaylistIoService io, IArtworkCache artwork, IPlaybackService playback, NotificationService notifications, DialogService dialogs)
    {
        _playlists = playlists;
        _io = io;
        _artwork = artwork;
        _playback = playback;
        _notifications = notifications;
        _dialogs = dialogs;
    }

    public ObservableCollection<PlaylistEntryItemViewModel> Entries { get; } = new();
    [ObservableProperty] private string _name = "Playlist";
    [ObservableProperty] private string _subtitle = "";
    [ObservableProperty] private bool _isSmart;
    [ObservableProperty] private string? _artworkPath;
    [ObservableProperty] private bool _isEmpty;
    [ObservableProperty] private Playlist? _playlist;

    public async Task LoadAsync(long playlistId)
    {
        Playlist = await _playlists.GetAsync(playlistId);
        if (Playlist is null) { IsEmpty = true; return; }
        Name = Playlist.Name;
        IsSmart = Playlist.IsSmart;
        ArtworkPath = _artwork.GetThumbnailPath(Playlist.ArtworkHash, 512);
        Entries.Clear();
        IReadOnlyList<Track> smartTracks = Array.Empty<Track>();
        if (Playlist.IsSmart && Playlist.Smart is { } def)
        {
            var tracksRepo = Microsoft.Extensions.DependencyInjection.ServiceProviderServiceExtensions.GetRequiredService<ITrackRepository>(App.Services);
            smartTracks = await tracksRepo.QuerySmartAsync(def);
        }
        if (smartTracks.Count > 0)
        {
            var pos = 0;
            foreach (var t in smartTracks)
                Entries.Add(new PlaylistEntryItemViewModel
                {
                    Entry = new PlaylistEntry { PlaylistId = Playlist.Id, Position = pos++, Track = t, SourceUri = t.SourceUri, Title = t.DisplayTitle, Artist = t.DisplayArtist, DurationMs = t.DurationMs },
                    ArtworkPath = _artwork.GetThumbnailPath(t.ArtworkHash, 64),
                });
        }
        else
        {
            foreach (var e in await _playlists.GetEntriesAsync(playlistId))
                Entries.Add(new PlaylistEntryItemViewModel { Entry = e, ArtworkPath = _artwork.GetThumbnailPath(e.Track?.ArtworkHash, 64) });
        }
        IsEmpty = Entries.Count == 0;
        Subtitle = $"{Entries.Count} track{(Entries.Count == 1 ? "" : "s")} \u00B7 {Formatters.Duration(Entries.Sum(e => e.Entry.Track?.DurationMs ?? e.Entry.DurationMs))}";
    }

    private List<Track> PlayableTracks() => Entries.Where(e => e.Entry.Track is not null).Select(e => e.Entry.Track!).ToList();

    [RelayCommand]
    private Task PlayAll()
    {
        var tracks = PlayableTracks();
        return tracks.Count == 0 ? Task.CompletedTask : _playback.PlayAsync(tracks, 0);
    }

    public async Task PlayEntryAsync(PlaylistEntryItemViewModel? item)
    {
        if (item is null) return;
        var tracks = PlayableTracks();
        var idx = tracks.FindIndex(t => t.SourceUri == item.Entry.SourceUri);
        if (idx >= 0) await _playback.PlayAsync(tracks, idx);
    }

    public async Task MoveAsync(int from, int to)
    {
        if (Playlist is null || IsSmart) return;
        await _playlists.MoveEntryAsync(Playlist.Id, from, to);
        await LoadAsync(Playlist.Id);
    }

    /// <summary>Persists the visual order after a drag-drop reorder of the bound collection.</summary>
    public async Task PersistOrderAsync()
    {
        if (Playlist is null || IsSmart) return;
        await _playlists.ReorderAsync(Playlist.Id, Entries.Select(e => e.Entry.Id).ToList());
        await LoadAsync(Playlist.Id);
    }

    public async Task RemoveAsync(PlaylistEntryItemViewModel? item)
    {
        if (item is null || Playlist is null || IsSmart) return;
        await _playlists.RemoveEntriesAsync(Playlist.Id, new[] { item.Entry.Id });
        await LoadAsync(Playlist.Id);
    }

    [RelayCommand]
    private async Task Export()
    {
        if (Playlist is null) return;
        var path = await _dialogs.PickSaveFileAsync(Playlist.Name + ".m3u8", ".m3u8",
            ("M3U8 playlist", ".m3u8"), ("M3U playlist", ".m3u"), ("PLS playlist", ".pls"));
        if (path is null) return;
        var format = Path.GetExtension(path).ToLowerInvariant() switch
        {
            ".m3u" => PlaylistFileFormat.M3u,
            ".pls" => PlaylistFileFormat.Pls,
            _ => PlaylistFileFormat.M3u8,
        };
        await _io.ExportAsync(Playlist.Id, path, format);
        _notifications.Success("Playlist exported", path);
    }
}

/// <summary>
/// Smart playlist rule editor. Pure view model: no DispatcherQueue, no XAML \u2014 safe to unit test.
/// </summary>
public sealed partial class SmartPlaylistEditorViewModel : ObservableObject
{
    private readonly ITrackRepository _tracks;
    private readonly IPlaylistRepository _playlists;
    private long? _playlistId;
    private int _countVersion;

    public SmartPlaylistEditorViewModel(ITrackRepository tracks, IPlaylistRepository playlists)
    {
        _tracks = tracks;
        _playlists = playlists;
    }

    public ObservableCollection<SmartRuleItem> Rules { get; } = new();

    [ObservableProperty] private string _name = "";
    [ObservableProperty] private bool _matchAll = true;
    [ObservableProperty] private string _sortText = "";
    [ObservableProperty] private double _limit;

    /// <summary>ComboBox-friendly proxy for <see cref="MatchAll"/>.</summary>
    public int MatchIndex
    {
        get => MatchAll ? 0 : 1;
        set => MatchAll = value == 0;
    }

    partial void OnMatchAllChanged(bool value)
    {
        OnPropertyChanged(nameof(MatchIndex));
        ScheduleCount();
    }
    [ObservableProperty] private string _liveCount = "";
    [ObservableProperty] private bool _isCounting;

    public static IReadOnlyList<string> Fields { get; } = SmartPlaylistCompiler.SupportedFields.OrderBy(f => f).ToList();
    public static IReadOnlyList<string> Ops => SmartPlaylistCompiler.SupportedOps;

    public void LoadFrom(Playlist playlist)
    {
        _playlistId = playlist.Id;
        Name = playlist.Name;
        var def = playlist.Smart ?? new SmartPlaylistDefinition();
        MatchAll = def.Match != "any";
        SortText = def.Sort ?? "";
        Limit = def.Limit;
        Rules.Clear();
        foreach (var r in def.Rules)
        {
            var item = SmartRuleItem.From(r, this);
            item.RemoveCommandProxy = RemoveRuleCommand;
            Rules.Add(item);
        }
        if (Rules.Count == 0) AddRule();
        ScheduleCount();
    }

    public void NewDefinition(string name)
    {
        _playlistId = null;
        Name = name;
        MatchAll = true;
        SortText = "";
        Limit = 0;
        Rules.Clear();
        AddRule();
    }

    [RelayCommand]
    private void AddRule()
    {
        var item = new SmartRuleItem(this) { RemoveCommandProxy = RemoveRuleCommand };
        Rules.Add(item);
        OnPropertyChanged(nameof(IsValid));
        ScheduleCount();
    }

    [RelayCommand]
    private void RemoveRule(SmartRuleItem? item)
    {
        if (item is null || Rules.Count <= 1) return;
        Rules.Remove(item);
        OnPropertyChanged(nameof(IsValid));
        ScheduleCount();
    }

    public void OnRuleChanged()
    {
        OnPropertyChanged(nameof(IsValid));
        ScheduleCount();
    }

    partial void OnSortTextChanged(string value) => ScheduleCount();
    partial void OnLimitChanged(double value) => ScheduleCount();

    public SmartPlaylistDefinition BuildDefinition() => new()
    {
        Name = Name,
        Match = MatchAll ? "all" : "any",
        Rules = Rules.Where(r => r.IsComplete).Select(r => r.ToRule()).ToList(),
        Sort = string.IsNullOrWhiteSpace(SortText) ? null : SortText.Trim(),
        Limit = (int)Limit,
    };

    public bool IsValid => Name.Trim().Length > 0 && Rules.Any(r => r.IsComplete);
    partial void OnNameChanged(string value) => OnPropertyChanged(nameof(IsValid));

    /// <summary>Debounced live match count. Version counter makes out-of-order results harmless.</summary>
    private async void ScheduleCount()
    {
        var version = ++_countVersion;
        IsCounting = true;
        await Task.Delay(350);
        if (version != _countVersion) return;
        try
        {
            var def = BuildDefinition();
            if (def.Rules.Count == 0) { LiveCount = "Add a rule to see matches."; IsCounting = false; return; }
            var matches = await _tracks.QuerySmartAsync(def);
            if (version != _countVersion) return;
            LiveCount = $"{matches.Count} track{(matches.Count == 1 ? "" : "s")} match{(matches.Count == 1 ? "es" : "")}";
        }
        catch (Exception ex)
        {
            if (version == _countVersion) LiveCount = ex.Message;
        }
        finally
        {
            if (version == _countVersion) IsCounting = false;
        }
    }

    public async Task<Playlist?> SaveAsync()
    {
        if (!IsValid) return null;
        var def = BuildDefinition();
        Playlist playlist;
        if (_playlistId is { } id)
        {
            await _playlists.RenameAsync(id, Name.Trim());
            await _playlists.UpdateSmartAsync(id, def);
            playlist = (await _playlists.GetAsync(id))!;
        }
        else
        {
            playlist = await _playlists.CreateAsync(Name.Trim(), def);
            _playlistId = playlist.Id;
        }
        return playlist;
    }
}

/// <summary>One smart playlist rule row.</summary>
public sealed partial class SmartRuleItem : ObservableObject
{
    private readonly SmartPlaylistEditorViewModel _parent;

    public SmartRuleItem(SmartPlaylistEditorViewModel parent)
    {
        _parent = parent;
        _field = "genre";
        _op = "contains";
    }

    [ObservableProperty] private string _field = "genre";
    [ObservableProperty] private string _op = "contains";
    [ObservableProperty] private string _value = "";
    [ObservableProperty] private string _value2 = "";

    public IReadOnlyList<string> FieldsList => SmartPlaylistEditorViewModel.Fields;
    public IReadOnlyList<string> OpsList => SmartPlaylistEditorViewModel.Ops;
    public CommunityToolkit.Mvvm.Input.IRelayCommand<SmartRuleItem>? RemoveCommandProxy { get; set; }

    /// <summary>Numeric-ish fields get number-style ops by default; shown as a hint in the UI.</summary>
    public bool IsNumericField => Field is "year" or "rating" or "playCount" or "bpm" or "bitrate" or "bitDepth" or "sampleRate" or "duration" or "favorite";
    public bool NeedsValue2 => Op == "between";

    public bool IsComplete => Value.Trim().Length > 0 && (!NeedsValue2 || Value2.Trim().Length > 0);

    partial void OnFieldChanged(string value)
    {
        OnPropertyChanged(nameof(IsNumericField));
        if (IsNumericField && Op is "contains" or "startsWith") Op = "is";
        if (!IsNumericField && Op is "gt" or "lt" or "between") Op = "contains";
        _parent.OnRuleChanged();
    }

    partial void OnOpChanged(string value)
    {
        OnPropertyChanged(nameof(NeedsValue2));
        _parent.OnRuleChanged();
    }

    partial void OnValueChanged(string value) => _parent.OnRuleChanged();
    partial void OnValue2Changed(string value) => _parent.OnRuleChanged();

    public static SmartRuleItem From(SmartRule rule, SmartPlaylistEditorViewModel parent) => new(parent)
    {
        Field = rule.Field,
        Op = rule.Op,
        Value = JsonValue(rule.Value),
        Value2 = JsonValue(rule.Value2),
    };

    public SmartRule ToRule() => new()
    {
        Field = Field,
        Op = Op,
        Value = ToJson(Value),
        Value2 = NeedsValue2 ? ToJson(Value2) : null,
    };

    private JsonNode ToJson(string text)
    {
        if (IsNumericField && double.TryParse(text, System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out var n))
            return System.Text.Json.Nodes.JsonValue.Create(n)!;
        return System.Text.Json.Nodes.JsonValue.Create(text.Trim())!;
    }

    private static string JsonValue(JsonNode? node) => node switch
    {
        null => "",
        JsonValue v when v.TryGetValue<double>(out var d) => d.ToString(System.Globalization.CultureInfo.InvariantCulture),
        JsonValue v when v.TryGetValue<string>(out var s) => s,
        _ => node.ToJsonString(),
    };
}

/// <summary>Bookmarks page.</summary>
public sealed partial class BookmarksViewModel : ObservableObject
{
    private readonly Core.Data.IBookmarkRepository _bookmarks;
    private readonly ITrackRepository _tracks;
    private readonly IPlaybackService _playback;

    public BookmarksViewModel(Core.Data.IBookmarkRepository bookmarks, ITrackRepository tracks, IPlaybackService playback)
    {
        _bookmarks = bookmarks;
        _tracks = tracks;
        _playback = playback;
    }

    public ObservableCollection<Bookmark> Bookmarks { get; } = new();
    [ObservableProperty] private bool _isEmpty;

    public async Task LoadAsync()
    {
        Bookmarks.Clear();
        foreach (var b in await _bookmarks.GetAllAsync()) Bookmarks.Add(b);
        IsEmpty = Bookmarks.Count == 0;
    }

    [RelayCommand]
    private async Task GoTo(Bookmark? bookmark)
    {
        if (bookmark is null) return;
        var track = await _tracks.GetBySourceUriAsync(bookmark.SourceUri);
        if (track is null) return;
        await _playback.PlayAsync(new[] { track }, 0, TimeSpan.FromMilliseconds(bookmark.PositionMs));
    }

    [RelayCommand]
    private async Task Delete(Bookmark? bookmark)
    {
        if (bookmark is null) return;
        await _bookmarks.DeleteAsync(bookmark.Id);
        Bookmarks.Remove(bookmark);
        IsEmpty = Bookmarks.Count == 0;
    }
}
