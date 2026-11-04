namespace MuurMusic.Core.Models;

/// <summary>Knowledge about audio file extensions and codecs.</summary>
public static class AudioFormats
{
    public static readonly IReadOnlySet<string> AudioExtensions = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
        ".flac", ".alac", ".wav", ".wave", ".aif", ".aiff", ".aifc", ".dsf", ".dff", ".ape", ".wv", ".tta",
        ".mp3", ".mp2", ".m4a", ".m4b", ".aac", ".ogg", ".oga", ".opus", ".mpc", ".mp+", ".mpp", ".ac3", ".eac3", ".dts",
        ".wma", ".asf", ".mp4", ".m4v", ".mkv", ".mka", ".webm", ".mov", ".mpg", ".mpeg", ".caf", ".spx", ".3gp",
        ".mod", ".xm", ".it", ".s3m", ".mptm", ".669", ".mtm", ".umx", ".w64", ".rf64", ".au", ".snd", ".shn", ".tak", ".ofr"
    };

    public static readonly IReadOnlySet<string> PlaylistExtensions = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
        ".m3u", ".m3u8", ".cue", ".pls", ".muursmart.json"
    };

    public static readonly IReadOnlySet<string> ArchiveExtensions = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { ".zip" };

    public static readonly IReadOnlySet<string> ImageExtensions = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { ".jpg", ".jpeg", ".png", ".webp", ".bmp", ".gif" };

    /// <summary>Extensions handled by TagLib# for reading and writing tags.</summary>
    public static readonly IReadOnlySet<string> TagLibExtensions = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
        ".flac", ".wav", ".aif", ".aiff", ".dsf", ".ape", ".wv", ".tta", ".mp3", ".mp2", ".m4a", ".m4b", ".aac", ".ogg", ".oga", ".opus",
        ".mpc", ".mp+", ".mpp", ".wma", ".asf", ".mp4", ".m4v", ".mkv", ".mka", ".webm", ".spx", ".3gp"
    };

    private static readonly HashSet<string> LosslessCodecs = new(StringComparer.OrdinalIgnoreCase)
    {
        "FLAC", "ALAC", "WAV", "PCM", "AIFF", "DSD", "APE", "WavPack", "TTA", "WMA Lossless", "TAK", "Shorten", "OptimFROG", "MLP", "TrueHD"
    };

    public static bool IsAudioFile(string path) => AudioExtensions.Contains(Path.GetExtension(path));
    public static bool IsPlaylistFile(string path) =>
        path.EndsWith(".muursmart.json", StringComparison.OrdinalIgnoreCase) || PlaylistExtensions.Contains(Path.GetExtension(path));
    public static bool IsArchiveFile(string path) => ArchiveExtensions.Contains(Path.GetExtension(path));
    public static bool IsLosslessCodec(string? codec) => codec is not null && (LosslessCodecs.Contains(codec) || codec.StartsWith("PCM", StringComparison.OrdinalIgnoreCase) || codec.StartsWith("DSD", StringComparison.OrdinalIgnoreCase));

    /// <summary>Maps an extension to a display codec name when the real codec is not known yet.</summary>
    public static string CodecFromExtension(string path) => Path.GetExtension(path).ToLowerInvariant() switch
    {
        ".flac" => "FLAC",
        ".alac" => "ALAC",
        ".wav" or ".wave" or ".w64" or ".rf64" => "PCM",
        ".aif" or ".aiff" or ".aifc" => "AIFF",
        ".dsf" or ".dff" => "DSD",
        ".ape" => "APE",
        ".wv" => "WavPack",
        ".tta" => "TTA",
        ".mp3" => "MP3",
        ".mp2" => "MP2",
        ".m4a" or ".m4b" or ".aac" or ".mp4" => "AAC",
        ".ogg" or ".oga" => "Vorbis",
        ".opus" => "Opus",
        ".mpc" or ".mp+" or ".mpp" => "Musepack",
        ".ac3" => "AC3",
        ".eac3" => "E-AC3",
        ".dts" => "DTS",
        ".wma" or ".asf" => "WMA",
        ".tak" => "TAK",
        ".shn" => "Shorten",
        ".spx" => "Speex",
        ".mod" or ".xm" or ".it" or ".s3m" or ".mptm" or ".669" or ".mtm" or ".umx" => "Tracker",
        var e => e.TrimStart('.').ToUpperInvariant()
    };

    public static string MimeTypeFromExtension(string path) => Path.GetExtension(path).ToLowerInvariant() switch
    {
        ".flac" => "audio/flac",
        ".mp3" => "audio/mpeg",
        ".m4a" or ".m4b" or ".mp4" or ".alac" => "audio/mp4",
        ".aac" => "audio/aac",
        ".ogg" or ".oga" => "audio/ogg",
        ".opus" => "audio/ogg",
        ".wav" or ".wave" => "audio/wav",
        ".aif" or ".aiff" or ".aifc" => "audio/aiff",
        ".wma" or ".asf" => "audio/x-ms-wma",
        ".mka" or ".mkv" => "audio/x-matroska",
        ".webm" => "audio/webm",
        ".ape" => "audio/x-ape",
        ".wv" => "audio/x-wavpack",
        ".dsf" => "audio/x-dsf",
        ".dff" => "audio/x-dff",
        ".ac3" => "audio/ac3",
        ".mpc" => "audio/x-musepack",
        ".tta" => "audio/x-tta",
        _ => "application/octet-stream"
    };

    public static string FormatBadge(string? codec, int bitDepth, int sampleRate, int bitrate)
    {
        codec ??= "?";
        if (codec.StartsWith("DSD", StringComparison.OrdinalIgnoreCase))
        {
            // Library stores DSD at the 1-bit rate (e.g. 2822400). Express as DSD64/128/...
            var multiple = sampleRate > 0 ? (int)Math.Round(sampleRate / 44100.0) : 64;
            return $"DSD{multiple}";
        }
        if (IsLosslessCodec(codec) && sampleRate > 0)
        {
            var khz = sampleRate % 1000 == 0 ? (sampleRate / 1000).ToString() : (sampleRate / 1000.0).ToString("0.#", System.Globalization.CultureInfo.InvariantCulture);
            return bitDepth > 0 ? $"{codec} {bitDepth}/{khz}" : $"{codec} {khz} kHz";
        }
        return bitrate > 0 ? $"{codec} {bitrate}k" : codec;
    }
}
