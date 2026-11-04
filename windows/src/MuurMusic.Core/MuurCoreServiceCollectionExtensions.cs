using System.Net;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Logging;
using MuurMusic.Core.Data;
using MuurMusic.Core.Discovery;
using MuurMusic.Core.Downloads;
using MuurMusic.Core.Dsp;
using MuurMusic.Core.Infrastructure;
using MuurMusic.Core.Library;
using MuurMusic.Core.Lyrics;
using MuurMusic.Core.Metadata;
using MuurMusic.Core.Playback;
using MuurMusic.Core.Playlists;
using MuurMusic.Core.Security;
using MuurMusic.Core.Settings;
using MuurMusic.Core.Sources;
using MuurMusic.Core.Tags;

namespace MuurMusic.Core;

/// <summary>Options for <see cref="MuurCoreServiceCollectionExtensions.AddMuurCore"/>.</summary>
public sealed class MuurCoreOptions
{
    /// <summary>App data root. Null = %LOCALAPPDATA%\MuurMusic (or the MUURMUSIC_DATA environment variable).</summary>
    public string? DataRoot { get; set; }
    /// <summary>Folder containing appsettings.json / appsettings.Local.json. Null = <see cref="AppContext.BaseDirectory"/>.</summary>
    public string? ConfigurationDirectory { get; set; }
    /// <summary>Minimum level written to the rolling log files in AppPaths.LogsDirectory.</summary>
    public LogLevel MinimumLogLevel { get; set; } = LogLevel.Information;
    /// <summary>Also log to the debugger output window.</summary>
    public bool DebugLogging { get; set; }
}

public static class MuurCoreServiceCollectionExtensions
{
    /// <summary>
    /// Registers every Core service as a singleton: configuration (appsettings.json, appsettings.Local.json, MUURMUSIC_ environment
    /// variables), file logging, the "muur" named HttpClient, database + repositories (migrated on first resolve), settings,
    /// credentials, OAuth, sources, discovery, tags/artwork, scanner, lyrics, MusicBrainz, presets, downloads, queue store and
    /// playlist import/export. Call <see cref="MuurCoreStartup.InitializeAsync"/> after building the provider.
    /// </summary>
    public static IServiceCollection AddMuurCore(this IServiceCollection services, Action<MuurCoreOptions>? configure = null)
    {
        var options = new MuurCoreOptions();
        configure?.Invoke(options);
        services.TryAddSingleton(options);

        var paths = options.DataRoot is null ? new AppPaths() : new AppPaths(options.DataRoot);
        services.TryAddSingleton(paths);

        if (!services.Any(d => d.ServiceType == typeof(IConfiguration)))
        {
            var dir = options.ConfigurationDirectory ?? AppContext.BaseDirectory;
            var configuration = new ConfigurationBuilder()
                .SetBasePath(dir)
                .AddJsonFile("appsettings.json", optional: true, reloadOnChange: false)
                .AddJsonFile("appsettings.Local.json", optional: true, reloadOnChange: false)
                .AddJsonFile(Path.Combine(paths.Root, "appsettings.Local.json"), optional: true, reloadOnChange: false)
                .AddEnvironmentVariables("MUURMUSIC_")
                .Build();
            services.AddSingleton<IConfiguration>(configuration);
        }

        services.AddLogging(b =>
        {
            b.SetMinimumLevel(options.MinimumLogLevel);
            b.AddProvider(new FileLoggerProvider(paths.LogsDirectory, options.MinimumLogLevel));
            if (options.DebugLogging) b.AddDebug();
        });

        services.AddHttpClient(HttpClientNames.Default, c =>
            {
                c.DefaultRequestHeaders.UserAgent.ParseAdd(HttpClientNames.UserAgent);
                c.Timeout = TimeSpan.FromSeconds(100);
            })
            .ConfigurePrimaryHttpMessageHandler(() => new SocketsHttpHandler
            {
                AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate | DecompressionMethods.Brotli,
                PooledConnectionLifetime = TimeSpan.FromMinutes(5),
                ConnectTimeout = TimeSpan.FromSeconds(15),
                MaxConnectionsPerServer = 16
            })
            .SetHandlerLifetime(Timeout.InfiniteTimeSpan);

        services.TryAddSingleton<IEventDispatcher, EventDispatcher>();
        services.TryAddSingleton(sp =>
        {
            var db = new LibraryDatabase(sp.GetRequiredService<AppPaths>(), sp.GetService<ILogger<LibraryDatabase>>());
            db.EnsureMigrated();
            return db;
        });
        services.TryAddSingleton<ITrackRepository, TrackRepository>();
        services.TryAddSingleton<IPlaylistRepository, PlaylistRepository>();
        services.TryAddSingleton<IBookmarkRepository, BookmarkRepository>();
        services.TryAddSingleton<ISourceRepository, SourceRepository>();
        services.TryAddSingleton<IDownloadRepository, DownloadRepository>();
        services.TryAddSingleton<IPresetRepository, PresetRepository>();
        services.TryAddSingleton<IAudioCacheRepository, AudioCacheRepository>();
        services.TryAddSingleton<IKeyValueStore, KeyValueStore>();

        services.TryAddSingleton<ISettingsService, SettingsService>();
        services.TryAddSingleton<ICredentialStore>(sp => new DpapiCredentialStore(sp.GetRequiredService<AppPaths>().CredentialsPath));
        services.TryAddSingleton<IOAuthService, OAuthService>();
        services.TryAddSingleton<SourceContext>();
        services.TryAddSingleton<SourceManager>();
        services.TryAddSingleton<ISourceManager>(sp => sp.GetRequiredService<SourceManager>());
        services.TryAddSingleton<PlexAuthService>();
        services.TryAddSingleton<INetworkDiscovery, NetworkDiscovery>();

        services.TryAddSingleton<ITagService, TagService>();
        services.TryAddSingleton<IArtworkCache, ArtworkCache>();
        services.TryAddSingleton<ILibraryScanner>(sp => new LibraryScanner(
            sp.GetRequiredService<ITrackRepository>(), sp.GetRequiredService<ITagService>(), sp.GetRequiredService<IArtworkCache>(),
            sp.GetRequiredService<ISettingsService>(), sp.GetRequiredService<ILogger<LibraryScanner>>(), sp.GetService<IMediaProbe>()));
        services.TryAddSingleton<ILyricsService, LyricsService>();
        services.TryAddSingleton<IMusicBrainzService, MusicBrainzService>();
        services.TryAddSingleton<IPresetService, PresetService>();
        services.TryAddSingleton<IDownloadManager, DownloadManager>();
        services.TryAddSingleton<IQueueStore, QueueStore>();
        services.TryAddSingleton<IPlaylistIoService, PlaylistIoService>();
        return services;
    }
}

/// <summary>Startup sequence for Core services.</summary>
public static class MuurCoreStartup
{
    /// <summary>
    /// Migrates the database, loads sources, restarts pending downloads, starts folder watching and (when
    /// <see cref="AppSettings.ScanOnStartup"/> is on) runs an incremental library scan in the background.
    /// </summary>
    public static async Task InitializeAsync(IServiceProvider services, CancellationToken ct = default)
    {
        services.GetRequiredService<LibraryDatabase>();
        var log = services.GetRequiredService<ILoggerFactory>().CreateLogger("MuurMusic.Startup");
        await services.GetRequiredService<ISourceManager>().InitializeAsync(ct).ConfigureAwait(false);
        await services.GetRequiredService<IDownloadManager>().InitializeAsync(ct).ConfigureAwait(false);
        var scanner = services.GetRequiredService<ILibraryScanner>();
        var settings = services.GetRequiredService<ISettingsService>().Current;
        scanner.StartWatching();
        if (settings.ScanOnStartup && settings.WatchedFolders.Count > 0)
        {
            _ = Task.Run(async () =>
            {
                try { await scanner.ScanAsync(null, false, ct).ConfigureAwait(false); }
                catch (OperationCanceledException) { }
                catch (Exception ex) { log.LogError(ex, "Startup scan failed"); }
            }, ct);
        }
    }
}
