using Microsoft.UI.Xaml.Controls;

namespace MuurMusic.App.Services;

/// <summary>Maps navigation keys to page types (resolved by name) and drives the content frame.</summary>
public sealed class NavigationService
{
    private static readonly Dictionary<string, string> Catalog = new(StringComparer.OrdinalIgnoreCase)
    {
        ["songs"] = "SongsPage",
        ["albums"] = "AlbumsPage",
        ["albumartists"] = "AlbumArtistsPage",
        ["artists"] = "ArtistsPage",
        ["genres"] = "GenresPage",
        ["composers"] = "ComposersPage",
        ["folders"] = "FoldersPage",
        ["playlists"] = "PlaylistsPage",
        ["bookmarks"] = "BookmarksPage",
        ["sources"] = "SourcesPage",
        ["files"] = "FileManagerPage",
        ["downloads"] = "DownloadsPage",
        ["history"] = "SimpleTrackListPage",
        ["recent"] = "SimpleTrackListPage",
        ["mostplayed"] = "SimpleTrackListPage",
        ["favorites"] = "SimpleTrackListPage",
        ["nowplaying"] = "NowPlayingPage",
        ["eq"] = "EqPage",
        ["effects"] = "EffectsPage",
        ["dsp"] = "DspChainPage",
        ["visualizer"] = "VisualizerPage",
        ["search"] = "SearchResultsPage",
        ["settings"] = "SettingsPage",
        ["album"] = "AlbumDetailPage",
        ["artist"] = "ArtistDetailPage",
        ["playlist"] = "PlaylistDetailPage",
        ["smarteditor"] = "SmartPlaylistEditorPage",
        ["source"] = "SourceBrowserPage",
    };

    private static readonly Dictionary<string, Type?> Cache = new(StringComparer.Ordinal);
    private Frame? _frame;

    public string? CurrentKey { get; private set; }

    /// <summary>Raised after a successful navigation so the shell can sync the selected nav item.</summary>
    public event EventHandler<string>? Navigated;

    public void Attach(Frame frame) => _frame = frame;

    public bool CanNavigate(string key) => Resolve(key) is not null;

    public bool Navigate(string key, object? parameter = null)
    {
        if (_frame is null || Resolve(key) is not { } page) return false;
        var ok = _frame.Navigate(page, parameter);
        if (ok)
        {
            CurrentKey = key;
            Navigated?.Invoke(this, key);
        }
        return ok;
    }

    private static Type? Resolve(string key)
    {
        if (!Catalog.TryGetValue(key, out var name)) return null;
        lock (Cache)
        {
            if (!Cache.TryGetValue(key, out var type))
            {
                type = typeof(NavigationService).Assembly.GetType("MuurMusic.App.Views." + name);
                Cache[key] = type;
            }
            return type;
        }
    }
}
