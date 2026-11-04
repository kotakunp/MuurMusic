using System.Runtime.InteropServices;
using FFmpeg.AutoGen;

namespace MuurMusic.Audio.FFmpeg;

/// <summary>
/// Locates and binds the FFmpeg 7.1 native libraries (avcodec-61, avformat-61, avutil-59, swresample-5) shipped by
/// the Sdcb.FFmpeg.runtime.windows-x64 package. They are copied next to the app executable; the runtimes\win-x64\native
/// sub-folder is also probed.
/// </summary>
public static unsafe class FFmpegLoader
{
    private static readonly object Gate = new();
    private static bool _loaded;

    public static string? NativeDirectory { get; private set; }
    public static string? Version { get; private set; }
    public static bool IsLoaded => _loaded;

    /// <summary>Overrides the probed folder (call before the first decoder is created).</summary>
    public static string? CustomDirectory { get; set; }

    public static void EnsureLoaded()
    {
        if (_loaded) return;
        lock (Gate)
        {
            if (_loaded) return;
            var dir = FindNativeDirectory() ?? throw new DllNotFoundException(
                "FFmpeg native libraries (avcodec-61.dll etc.) were not found next to the application. Make sure the Sdcb.FFmpeg.runtime.windows-x64 package assets are deployed.");
            NativeDirectory = dir;
            ffmpeg.RootPath = dir;
            DynamicallyLoadedBindings.Initialize();
            ffmpeg.av_log_set_level(ffmpeg.AV_LOG_ERROR);
            ffmpeg.avformat_network_init();
            Version = ffmpeg.av_version_info();
            _loaded = true;
        }
    }

    private static string? FindNativeDirectory()
    {
        var bases = new[] { CustomDirectory, AppContext.BaseDirectory, Path.GetDirectoryName(typeof(FFmpegLoader).Assembly.Location) }
            .Where(d => !string.IsNullOrEmpty(d)).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        foreach (var b in bases)
        {
            foreach (var candidate in new[] { b!, Path.Combine(b!, "runtimes", "win-x64", "native") })
                if (File.Exists(Path.Combine(candidate, "avcodec-61.dll"))) return candidate;
        }
        return null;
    }

    internal static string ErrorString(int error)
    {
        const int size = 1024;
        var buffer = stackalloc byte[size];
        ffmpeg.av_strerror(error, buffer, size);
        return Marshal.PtrToStringUTF8((IntPtr)buffer) ?? $"error {error}";
    }

    internal static string? DictGet(AVDictionary* dict, string key)
    {
        var e = ffmpeg.av_dict_get(dict, key, null, 0);
        return e == null ? null : Marshal.PtrToStringUTF8((IntPtr)e->value);
    }

    internal static void ReadDict(AVDictionary* dict, IDictionary<string, string> into)
    {
        AVDictionaryEntry* e = null;
        while ((e = ffmpeg.av_dict_get(dict, "", e, ffmpeg.AV_DICT_IGNORE_SUFFIX)) != null)
        {
            var k = Marshal.PtrToStringUTF8((IntPtr)e->key);
            var v = Marshal.PtrToStringUTF8((IntPtr)e->value);
            if (string.IsNullOrEmpty(k) || v is null) continue;
            k = k.ToUpperInvariant();
            if (!into.ContainsKey(k)) into[k] = v;
        }
    }
}
