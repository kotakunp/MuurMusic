using System.Text.Json;
using System.Text.Json.Serialization;
using MuurMusic.Core.Models;

namespace MuurMusic.Core.Settings;

public enum ReplayGainMode { Off, Track, Album }
public enum ThemeMode { System, Dark, Light }

/// <summary>All persisted user settings (settings.json). Mutate only through <see cref="ISettingsService.Update"/>.</summary>
public sealed class AppSettings
{
    // Appearance
    public ThemeMode Theme { get; set; } = ThemeMode.System;
    /// <summary>Amber (default), Violet, Mint, Rose, Sky.</summary>
    public string Accent { get; set; } = "Amber";
    /// <summary>Artwork, Vinyl or Visualizer.</summary>
    public string NowPlayingStyle { get; set; } = "Artwork";
    public List<string> TabsOrder { get; set; } = new() { "Songs", "Albums", "Artists", "AlbumArtists", "Genres", "Composers", "Folders", "Playlists" };
    public string VisualizerPreset { get; set; } = "SpectrumBars";
    public bool VisualizerAutoCycle { get; set; }
    public int VisualizerAutoCycleSeconds { get; set; } = 30;
    public bool ShowToastOnTrackChange { get; set; }
    public bool MiniPlayerAlwaysOnTop { get; set; } = true;

    // Output / playback
    /// <summary>WASAPI endpoint id; null follows the system default device.</summary>
    public string? OutputDeviceId { get; set; }
    public bool ExclusiveMode { get; set; }
    /// <summary>Requested output sample rate in Hz. 0 = match source (exclusive) / device mix rate (shared).</summary>
    public int OutputSampleRate { get; set; }
    public int OutputBufferMs { get; set; } = 100;
    public bool Gapless { get; set; } = true;
    public double CrossfadeSeconds { get; set; }
    public ReplayGainMode ReplayGain { get; set; } = ReplayGainMode.Off;
    public double ReplayGainPreampDb { get; set; }
    /// <summary>Gain applied to files without ReplayGain tags when ReplayGain is on.</summary>
    public double ReplayGainUntaggedDb { get; set; }
    public bool ReplayGainClipPrevention { get; set; } = true;
    public double Volume { get; set; } = 0.8;
    public bool Muted { get; set; }
    public double Speed { get; set; } = 1.0;
    public int SkipBackSeconds { get; set; } = 10;
    public int SkipForwardSeconds { get; set; } = 30;
    public bool RememberQueue { get; set; } = true;
    public bool ResumePlaybackOnStartup { get; set; }
    public bool Shuffle { get; set; }
    public RepeatMode Repeat { get; set; } = RepeatMode.Off;
    /// <summary>Use the SoX resampler (higher quality) instead of the default swresample filter.</summary>
    public bool HighQualityResampler { get; set; } = true;

    // Sound
    public bool EqEnabled { get; set; }
    public string EqPresetName { get; set; } = "Flat";
    public double EqPreampDb { get; set; }
    public double[] EqBands { get; set; } = new double[10];
    public bool DspChainEnabled { get; set; }
    /// <summary>Active DSP chain in muur-dsp JSON format (null = empty chain).</summary>
    public string? DspChainJson { get; set; }
    public bool LoudnessBoostEnabled { get; set; }
    /// <summary>0..12 dB of boost before the look-ahead limiter.</summary>
    public double LoudnessBoostDb { get; set; } = 6;

    // Library
    public List<string> WatchedFolders { get; set; } = new();
    public List<string> ExcludedFolders { get; set; } = new();
    public bool ScanOnStartup { get; set; } = true;
    public bool WatchForChanges { get; set; } = true;
    public int MinTrackSeconds { get; set; }
    public bool ExpandCueSheets { get; set; } = true;

    // Lyrics / metadata
    public bool FetchLyricsOnline { get; set; } = true;
    public bool FetchArtworkOnline { get; set; } = true;

    // Offline / cache / downloads
    public bool OfflineMode { get; set; }
    public bool AudioCacheEnabled { get; set; } = true;
    public long AudioCacheMaxBytes { get; set; } = 2L * 1024 * 1024 * 1024;
    public int DownloadConcurrency { get; set; } = 3;
    public string? DownloadFolder { get; set; }
    public bool PrefetchNextTrack { get; set; } = true;
    public int StreamBufferSeconds { get; set; } = 15;

    // Casting
    public string? LastCastDeviceId { get; set; }

    public AppSettings Clone() => JsonSerializer.Deserialize<AppSettings>(JsonSerializer.Serialize(this, SettingsJson.Options), SettingsJson.Options)!;
}

internal static class SettingsJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true
    };
}
