using MuurMusic.Audio.Engine;

namespace MuurMusic.Audio.Output;

/// <summary>A system render endpoint.</summary>
public sealed record OutputDeviceInfo(string Id, string FriendlyName, bool IsDefault, bool IsActive);

/// <summary>Plays an <see cref="AudioEngine"/> on a Windows audio endpoint. All members are called from the playback worker thread; events may arrive on COM callback threads.</summary>
public interface IAudioOutput : IDisposable
{
    /// <summary>The render thread died with an error (device unplugged, driver failure).</summary>
    event EventHandler<Exception>? PlaybackError;
    /// <summary>Devices were added, removed or changed state; re-query <see cref="GetDevices"/>.</summary>
    event EventHandler? DeviceListChanged;
    /// <summary>The system default render device changed. Only relevant while <see cref="DeviceId"/> is null (following the default).</summary>
    event EventHandler? DefaultDeviceChanged;

    IReadOnlyList<OutputDeviceInfo> GetDevices();
    /// <summary>Id of the endpoint in use, or null when following the system default.</summary>
    string? DeviceId { get; }
    /// <summary>Friendly name of the endpoint currently in use.</summary>
    string? DeviceName { get; }
    OutputFormatInfo? Format { get; }
    bool IsOpen { get; }
    bool IsPlaying { get; }
    TimeSpan Latency { get; }

    /// <summary>
    /// Negotiates a stream format and prepares the endpoint without starting rendering.
    /// <paramref name="requestedSampleRate"/> &gt; 0 pins the rate (exclusive mode); 0 uses the source rate (exclusive) or the device mix rate (shared).
    /// </summary>
    OutputFormatInfo Prepare(string? deviceId, bool exclusive, int requestedSampleRate, int sourceSampleRate, int sourceChannels, int bufferMs);
    /// <summary>Starts rendering. The engine must already be configured to <see cref="Format"/>.</summary>
    void Start(AudioEngine engine);
    void PausePlayback();
    void ResumePlayback();
    /// <summary>Stops rendering and releases the endpoint. The instance stays usable.</summary>
    void Close();
}
