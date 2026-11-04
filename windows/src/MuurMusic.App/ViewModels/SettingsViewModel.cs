using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.Extensions.DependencyInjection;
using MuurMusic.App.Services;
using MuurMusic.Audio.Output;
using MuurMusic.Audio.Playback;
using MuurMusic.Core.Data;
using MuurMusic.Core.Downloads;
using MuurMusic.Core.Infrastructure;
using MuurMusic.Core.Library;
using MuurMusic.Core.Models;
using MuurMusic.Core.Settings;
using MuurMusic.Core.Tags;

namespace MuurMusic.App.ViewModels;

/// <summary>Settings page: appearance, playback, audio, library, downloads and about.</summary>
public sealed partial class SettingsViewModel : ObservableObject
{
    private readonly ISettingsService _settings;
    private readonly IPlaybackService _playback;
    private readonly ILibraryScanner _scanner;
    private readonly IDownloadManager _downloads;
    private readonly ITrackRepository _tracks;
    private readonly NotificationService _notifications;
    private int _aboutClicks;

    public SettingsViewModel(ISettingsService settings, IPlaybackService playback, ILibraryScanner scanner,
        IDownloadManager downloads, ITrackRepository tracks, NotificationService notifications)
    {
        _settings = settings;
        _playback = playback;
        _scanner = scanner;
        _downloads = downloads;
        _tracks = tracks;
        _notifications = notifications;

        WatchedFolders = new ObservableCollection<string>(_settings.Current.WatchedFolders);
        Themes = new[] { "System", "Dark", "Light" };
        Accents = new[] { "DustyRose", "LavenderMist", "MutedTeal", "WarmApricot", "Sage", "Blue", "Purple", "Pink" };
        NowPlayingStyles = new[] { "Artwork", "Vinyl", "Visualizer" };
        ReplayGainModes = new[] { "Off", "Track", "Album" };
        VisualizerPresets = new[] { "SpectrumBars", "MirrorBars", "CircleSpectrum", "Waveform", "Particles", "CatEyes", "Starfield", "Vinyl" };
        StartPages = new[] { "Songs", "Albums", "Artists", "AlbumArtists", "Genres", "Composers", "Folders", "Playlists", "Favorites" };

        LoadDevices();
        LoadSizes();
    }

    private AppSettings S => _settings.Current;
    private void Update(Action<AppSettings> apply) => _settings.Update(apply);

    public IReadOnlyList<string> Themes { get; }
    public IReadOnlyList<string> Accents { get; }
    public IReadOnlyList<string> NowPlayingStyles { get; }
    public IReadOnlyList<string> ReplayGainModes { get; }
    public IReadOnlyList<string> VisualizerPresets { get; }
    public IReadOnlyList<string> StartPages { get; }
    public ObservableCollection<string> WatchedFolders { get; }
    public ObservableCollection<OutputDeviceInfo> Devices { get; } = new();

    [ObservableProperty] private bool _isScanning;
    [ObservableProperty] private string _cacheSize = "";
    [ObservableProperty] private string _offlineSize = "";
    [ObservableProperty] private string _libraryStats = "";
    [ObservableProperty] private string _versionText = "";
    [ObservableProperty] private string _easterEggText = "";

    // ---- Appearance ----
    public int ThemeIndex
    {
        get => (int)S.Theme;
        set => Update(s => s.Theme = (ThemeMode)Math.Clamp(value, 0, 2));
    }

    public string Accent
    {
        get => S.Accent;
        set => Update(s => s.Accent = value);
    }

    public int NowPlayingStyleIndex
    {
        get => Math.Max(0, Array.IndexOf(NowPlayingStyles.ToArray(), S.NowPlayingStyle));
        set { if (value >= 0) Update(s => s.NowPlayingStyle = NowPlayingStyles[value]); }
    }

    public bool ShowToastOnTrackChange
    {
        get => S.ShowToastOnTrackChange;
        set => Update(s => s.ShowToastOnTrackChange = value);
    }

    public int VisualizerPresetIndex
    {
        get => Math.Max(0, Array.IndexOf(VisualizerPresets.ToArray(), S.VisualizerPreset));
        set { if (value >= 0) Update(s => s.VisualizerPreset = VisualizerPresets[value]); }
    }

    public bool VisualizerAutoCycle
    {
        get => S.VisualizerAutoCycle;
        set => Update(s => s.VisualizerAutoCycle = value);
    }

    public double VisualizerAutoCycleSeconds
    {
        get => S.VisualizerAutoCycleSeconds;
        set => Update(s => s.VisualizerAutoCycleSeconds = (int)value);
    }

    // ---- Start page ----
    public int StartPageIndex
    {
        get
        {
            var key = S.TabsOrder.Count > 0 ? S.TabsOrder[0] : "Songs";
            return Math.Max(0, Array.FindIndex(StartPages.ToArray(), p => string.Equals(p, key, StringComparison.OrdinalIgnoreCase)));
        }
        set
        {
            if (value < 0) return;
            var chosen = StartPages[value];
            Update(s =>
            {
                s.TabsOrder.RemoveAll(t => string.Equals(t, chosen, StringComparison.OrdinalIgnoreCase));
                s.TabsOrder.Insert(0, chosen);
            });
        }
    }

    // ---- Playback ----
    public bool Gapless
    {
        get => S.Gapless;
        set => Update(s => s.Gapless = value);
    }

    public double CrossfadeSeconds
    {
        get => S.CrossfadeSeconds;
        set => Update(s => s.CrossfadeSeconds = (int)value);
    }

    public int ReplayGainIndex
    {
        get => (int)S.ReplayGain;
        set => Update(s => s.ReplayGain = (ReplayGainMode)Math.Clamp(value, 0, 2));
    }

    public bool LoudnessBoostEnabled
    {
        get => S.LoudnessBoostEnabled;
        set => Update(s => s.LoudnessBoostEnabled = value);
    }

    // ---- Audio ----
    public OutputDeviceInfo? SelectedDevice
    {
        get => Devices.FirstOrDefault(d => d.Id == S.OutputDeviceId) ?? Devices.FirstOrDefault(d => d.IsDefault);
        set
        {
            if (value is null) return;
            Update(s => s.OutputDeviceId = value.IsDefault ? null : value.Id);
            _ = ReopenAsync();
        }
    }

    public bool ExclusiveMode
    {
        get => S.ExclusiveMode;
        set
        {
            Update(s => s.ExclusiveMode = value);
            _ = ReopenAsync();
        }
    }

    private async Task ReopenAsync()
    {
        try { await _playback.ReopenOutputAsync(); }
        catch (Exception ex) { _notifications.Warning("Audio output", ex.Message); }
    }

    private void LoadDevices()
    {
        Devices.Clear();
        try
        {
            foreach (var d in _playback.GetOutputDevices()) Devices.Add(d);
        }
        catch { /* audio not initialised yet */ }
    }

    // ---- Library ----
    public bool ScanOnStartup
    {
        get => S.ScanOnStartup;
        set => Update(s => s.ScanOnStartup = value);
    }

    public bool OfflineMode
    {
        get => S.OfflineMode;
        set => Update(s => s.OfflineMode = value);
    }

    [RelayCommand]
    private async Task AddFolder()
    {
        var folder = await App.Services.GetRequiredService<DialogService>().PickFolderAsync("Add music folder");
        if (folder is null || WatchedFolders.Contains(folder, StringComparer.OrdinalIgnoreCase)) return;
        WatchedFolders.Add(folder);
        Update(s =>
        {
            if (!s.WatchedFolders.Contains(folder)) s.WatchedFolders.Add(folder);
        });
        await _scanner.AddFolderAsync(folder);
        _notifications.Success("Folder added", folder);
    }

    [RelayCommand]
    private void RemoveFolder(string? folder)
    {
        if (folder is null) return;
        WatchedFolders.Remove(folder);
        Update(s => s.WatchedFolders.Remove(folder));
    }

    [RelayCommand]
    private async Task RescanNow()
    {
        IsScanning = true;
        try
        {
            await _scanner.ScanAsync(full: true);
            await LoadLibraryStatsAsync();
            _notifications.Success("Scan finished", LibraryStats);
        }
        finally { IsScanning = false; }
    }

    public async Task LoadLibraryStatsAsync()
    {
        var total = await _tracks.CountAsync(new TrackQuery());
        var albums = await _tracks.GetAlbumsAsync(new AlbumQuery { Limit = 100000 });
        LibraryStats = $"{total} tracks · {albums.Count} albums";
    }

    // ---- Downloads ----
    public string DownloadFolder
    {
        get => S.DownloadFolder ?? "";
        set => Update(s => s.DownloadFolder = value);
    }

    public double DownloadConcurrency
    {
        get => S.DownloadConcurrency;
        set => Update(s => s.DownloadConcurrency = (int)value);
    }

    public bool AudioCacheEnabled
    {
        get => S.AudioCacheEnabled;
        set => Update(s => s.AudioCacheEnabled = value);
    }

    public double AudioCacheMaxGb
    {
        get => S.AudioCacheMaxBytes / 1073741824.0;
        set => Update(s => s.AudioCacheMaxBytes = (long)(value * 1073741824));
    }

    [RelayCommand]
    private async Task PickDownloadFolder()
    {
        var folder = await App.Services.GetRequiredService<DialogService>().PickFolderAsync("Choose download folder");
        if (folder is not null) { DownloadFolder = folder; OnPropertyChanged(nameof(DownloadFolder)); }
    }

    [RelayCommand]
    private void OpenDownloadFolder() => OpenPath(DownloadFolder);

    [RelayCommand]
    private void OpenLogsFolder() => OpenPath(App.Services.GetRequiredService<AppPaths>().LogsDirectory);

    [RelayCommand]
    private void OpenDataFolder() => OpenPath(App.Services.GetRequiredService<AppPaths>().Root);

    private static void OpenPath(string path)
    {
        try
        {
            System.IO.Directory.CreateDirectory(path);
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe", $"\"{path}\"") { UseShellExecute = true });
        }
        catch { /* best effort */ }
    }

    [RelayCommand]
    private async Task ClearCache()
    {
        await _downloads.ClearCacheAsync();
        await LoadSizesAsync();
        _notifications.Success("Cache cleared", "Streamed audio cache emptied.");
    }

    [RelayCommand]
    private async Task EnforceCacheLimit()
    {
        await _downloads.EnforceCacheLimitAsync();
        await LoadSizesAsync();
    }

    private void LoadSizes() => _ = LoadSizesAsync();

    private async Task LoadSizesAsync()
    {
        CacheSize = Formatters.Bytes(await _downloads.GetCacheSizeAsync());
        OfflineSize = Formatters.Bytes(_downloads.GetOfflineSize());
    }

    // ---- About ----
    [RelayCommand]
    private void AboutClicked()
    {
        _aboutClicks++;
        EasterEggText = _aboutClicks switch
        {
            < 3 => "",
            3 => "The cat stirs...",
            4 => "The cat is nearly awake...",
            _ => "Meow. MuurMusic is 100% powered by purring. \U0001F431",
        };
        if (_aboutClicks == 5)
            _notifications.Info("Easter egg", "You found the cat. It is unimpressed, but grateful.");
    }

    public void SetVersion()
    {
        var asm = System.Reflection.Assembly.GetExecutingAssembly().GetName();
        VersionText = $"MuurMusic {asm.Version?.ToString(3) ?? "1.0.0"}";
    }
}
