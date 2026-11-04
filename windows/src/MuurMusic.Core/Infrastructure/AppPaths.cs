namespace MuurMusic.Core.Infrastructure;

/// <summary>Locations of all app data under %LOCALAPPDATA%\MuurMusic (overridable for tests and portable mode).</summary>
public sealed class AppPaths
{
    public AppPaths() : this(Environment.GetEnvironmentVariable("MUURMUSIC_DATA") is { Length: > 0 } custom
        ? custom
        : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MuurMusic"))
    {
    }

    public AppPaths(string root)
    {
        Root = Path.GetFullPath(root);
        foreach (var dir in new[] { Root, ArtworkDirectory, ThumbnailDirectory, LyricsDirectory, AudioCacheDirectory, ArchiveCacheDirectory, OfflineDirectory, LogsDirectory, DownloadsTempDirectory })
            Directory.CreateDirectory(dir);
    }

    public string Root { get; }
    public string DatabasePath => Path.Combine(Root, "library.sqlite");
    public string SettingsPath => Path.Combine(Root, "settings.json");
    public string QueuePath => Path.Combine(Root, "queue.json");
    public string CredentialsPath => Path.Combine(Root, "credentials.dat");
    public string ArtworkDirectory => Path.Combine(Root, "Artwork");
    public string ThumbnailDirectory => Path.Combine(Root, "Artwork", "thumbs");
    public string LyricsDirectory => Path.Combine(Root, "Lyrics");
    public string AudioCacheDirectory => Path.Combine(Root, "Cache", "Audio");
    public string ArchiveCacheDirectory => Path.Combine(Root, "Cache", "Archives");
    public string OfflineDirectory => Path.Combine(Root, "Offline");
    public string LogsDirectory => Path.Combine(Root, "Logs");
    public string DownloadsTempDirectory => Path.Combine(Root, "Cache", "Partial");

    /// <summary>Default folder for user-visible downloads (Music\MuurMusic).</summary>
    public static string DefaultDownloadFolder => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyMusic), "MuurMusic");
}
