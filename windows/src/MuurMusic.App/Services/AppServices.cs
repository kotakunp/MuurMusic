using Microsoft.Extensions.DependencyInjection;
using MuurMusic.App.ViewModels;

namespace MuurMusic.App.Services;

/// <summary>Registers the app-layer services and view models on top of MuurCore/MuurAudio.</summary>
public static class AppServices
{
    public static IServiceCollection Register(IServiceCollection services)
    {
        services.AddSingleton<NotificationService>();
        services.AddSingleton<ThemeService>();
        services.AddSingleton<DialogService>();
        services.AddSingleton<NavigationService>();
        services.AddSingleton<ToastService>();
        services.AddSingleton<TaskbarService>();

        // View models (long-lived ones are singletons so pages keep their state).
        services.AddSingleton<PlayerBarViewModel>();
        services.AddSingleton<SongsViewModel>();
        services.AddSingleton<AlbumsViewModel>();
        services.AddSingleton<FoldersViewModel>();
        services.AddTransient<ArtistsViewModel>();
        services.AddTransient<GenresViewModel>();
        services.AddTransient<AlbumDetailViewModel>();
        services.AddTransient<ArtistDetailViewModel>();
        services.AddTransient<TrackListViewModel>();
        services.AddSingleton<NowPlayingViewModel>();
        services.AddTransient<VisualizerViewModel>();
        services.AddSingleton<EqViewModel>();
        services.AddSingleton<DspChainViewModel>();
        services.AddSingleton<SourcesViewModel>();
        services.AddTransient<SourceBrowserViewModel>();
        services.AddTransient<FileManagerViewModel>();
        services.AddSingleton<DownloadsViewModel>();
        services.AddSingleton<PlaylistsViewModel>();
        services.AddTransient<PlaylistDetailViewModel>();
        services.AddTransient<SmartPlaylistEditorViewModel>();
        services.AddSingleton<BookmarksViewModel>();
        services.AddTransient<SimpleTrackListViewModel>();
        services.AddTransient<SearchResultsViewModel>();
        services.AddTransient<SettingsViewModel>();
        services.AddTransient<EffectsViewModel>();
        return services;
    }
}
