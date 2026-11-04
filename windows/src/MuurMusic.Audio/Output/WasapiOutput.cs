using Microsoft.Extensions.Logging;
using MuurMusic.Audio.Engine;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace MuurMusic.Audio.Output;

/// <summary>
/// WASAPI output built on NAudio's <see cref="WasapiPlayer"/> (event-driven, MMCSS "Pro Audio" render thread).
/// Shared mode renders float32 at the device mix format; exclusive mode negotiates float32 → 32/24/16-bit at the
/// requested (or source) sample rate. Follows default-device changes and reports device hot-plug through events.
/// </summary>
public sealed class WasapiOutput : IAudioOutput
{
    private readonly ILogger<WasapiOutput>? _log;
    private readonly object _gate = new();
    private MMDeviceEnumerator? _enumerator;
    private MMDeviceNotificationClient? _notifications;
    private WasapiPlayer? _player;
    private string? _deviceId;
    private OutputFormatInfo? _format;
    private MMDevice? _device;
    private bool _disposed;

    public WasapiOutput(ILogger<WasapiOutput>? log = null) => _log = log;

    public event EventHandler<Exception>? PlaybackError;
    public event EventHandler? DeviceListChanged;
    public event EventHandler? DefaultDeviceChanged;

    public string? DeviceId => _deviceId;
    public string? DeviceName { get; private set; }
    public OutputFormatInfo? Format => _format;
    public bool IsOpen => _player is not null;
    public bool IsPlaying => _player?.PlaybackState == PlaybackState.Playing;
    public TimeSpan Latency => _player?.CurrentLatency ?? TimeSpan.Zero;

    private MMDeviceEnumerator Enumerator
    {
        get
        {
            if (_enumerator is not null) return _enumerator;
            _enumerator = new MMDeviceEnumerator();
            _notifications = _enumerator.CreateNotificationClient(false);
            _notifications.DeviceAdded += (_, _) => DeviceListChanged?.Invoke(this, EventArgs.Empty);
            _notifications.DeviceRemoved += (_, _) => DeviceListChanged?.Invoke(this, EventArgs.Empty);
            _notifications.DeviceStateChanged += (_, _) => DeviceListChanged?.Invoke(this, EventArgs.Empty);
            _notifications.DefaultDeviceChanged += (_, e) =>
            {
                if (e.Flow == DataFlow.Render && e.Role is Role.Multimedia or Role.Console)
                    DefaultDeviceChanged?.Invoke(this, EventArgs.Empty);
            };
            return _enumerator;
        }
    }

    public IReadOnlyList<OutputDeviceInfo> GetDevices()
    {
        var list = new List<OutputDeviceInfo>();
        try
        {
            string? defaultId = null;
            if (Enumerator.HasDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia))
                defaultId = Enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia).ID;
            foreach (var d in Enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active))
                list.Add(new OutputDeviceInfo(d.ID, d.FriendlyName, d.ID == defaultId, d.State == DeviceState.Active));
        }
        catch (Exception ex)
        {
            _log?.LogWarning(ex, "Enumerating audio endpoints failed");
        }
        return list;
    }

    private MMDevice ResolveDevice(string? deviceId)
    {
        if (deviceId is not null)
        {
            try { return Enumerator.GetDevice(deviceId); }
            catch (Exception ex)
            {
                _log?.LogWarning(ex, "Output device {Id} not found; falling back to the default device", deviceId);
            }
        }
        if (!Enumerator.HasDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia))
            throw new InvalidOperationException("No active audio output device found.");
        return Enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
    }

    public OutputFormatInfo Prepare(string? deviceId, bool exclusive, int requestedSampleRate, int sourceSampleRate, int sourceChannels, int bufferMs)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        lock (_gate)
        {
            CloseLocked();
            var device = ResolveDevice(deviceId);
            _device = device;
            _deviceId = deviceId is not null && device.ID == deviceId ? deviceId : null;
            DeviceName = device.FriendlyName;
            WaveFormat mix;
            using (var client = device.CreateAudioClient()) mix = client.MixFormat;
            var builder = new WasapiPlayerBuilder()
                .WithDevice(device)
                .WithLatency(Math.Clamp(bufferMs, 10, 500))
                .WithEventSync()
                .WithMmcssThreadPriority("Pro Audio");
            builder = exclusive ? builder.WithExclusiveMode() : builder.WithSharedMode();
            var player = builder.Build();
            try
            {
                OutputFormatInfo format;
                if (!exclusive)
                {
                    format = new OutputFormatInfo(mix.SampleRate, mix.Channels, OutputSampleEncoding.Float32, 32, false);
                }
                else
                {
                    var rate = requestedSampleRate > 0 ? requestedSampleRate : sourceSampleRate > 0 ? sourceSampleRate : mix.SampleRate;
                    var channels = sourceChannels is > 0 and <= 8 ? sourceChannels : mix.Channels;
                    format = NegotiateExclusive(player, rate, channels, mix);
                }
                if (!player.IsFormatSupported(format.ToWaveFormat()) && !exclusive)
                    throw new InvalidOperationException($"The device does not accept {format}.");
                _player = player;
                _player.PlaybackStopped += OnPlaybackStopped;
                _format = format;
                _log?.LogInformation("Output on {Device}: {Format}", DeviceName, format);
                return format;
            }
            catch
            {
                player.Dispose();
                throw;
            }
        }
    }

    private static OutputFormatInfo NegotiateExclusive(WasapiPlayer player, int rate, int channels, WaveFormat mix)
    {
        foreach (var enc in new[] { OutputSampleEncoding.Float32, OutputSampleEncoding.Int32, OutputSampleEncoding.Int24In32, OutputSampleEncoding.Int24, OutputSampleEncoding.Int16 })
        {
            var bits = enc == OutputSampleEncoding.Int16 ? 16 : enc is OutputSampleEncoding.Int24 or OutputSampleEncoding.Int24In32 ? 24 : 32;
            var candidate = new OutputFormatInfo(rate, channels, enc, bits, true);
            if (player.IsFormatSupported(candidate.ToWaveFormat())) return candidate;
        }
        // Ask the driver for the closest supported format, then the mix format as a last resort.
        var desired = new OutputFormatInfo(rate, channels, OutputSampleEncoding.Float32, 32, true).ToWaveFormat();
        try
        {
            var supported = player.GetSupportedExclusiveFormat(desired);
            if (supported is not null)
            {
                var enc = supported.Encoding == WaveFormatEncoding.IeeeFloat ? OutputSampleEncoding.Float32
                    : supported.BitsPerSample == 32 ? OutputSampleEncoding.Int32
                    : supported.BitsPerSample == 24 ? OutputSampleEncoding.Int24
                    : OutputSampleEncoding.Int16;
                return new OutputFormatInfo(supported.SampleRate, supported.Channels, enc, supported.BitsPerSample, true);
            }
        }
        catch (Exception) { /* fall through to the mix format */ }
        return new OutputFormatInfo(mix.SampleRate, mix.Channels, OutputSampleEncoding.Float32, 32, true);
    }

    public void Start(AudioEngine engine)
    {
        ArgumentNullException.ThrowIfNull(engine);
        lock (_gate)
        {
            var player = _player ?? throw new InvalidOperationException("Call Prepare first.");
            var format = _format!;
            if (engine.SampleRate != format.SampleRate || engine.Channels != format.Channels)
                throw new InvalidOperationException($"Engine format {engine.SampleRate}/{engine.Channels} does not match the negotiated output format {format.SampleRate}/{format.Channels}.");
            if (player.PlaybackState == PlaybackState.Playing) return;
            if (player.PlaybackState == PlaybackState.Paused) { player.Play(); return; }
            player.Init(new EngineWaveProvider(engine, format));
            player.Play();
        }
    }

    public void PausePlayback()
    {
        lock (_gate)
            if (_player?.PlaybackState == PlaybackState.Playing) _player.Pause();
    }

    public void ResumePlayback()
    {
        lock (_gate)
            if (_player?.PlaybackState == PlaybackState.Paused) _player.Play();
    }

    private void OnPlaybackStopped(object? sender, StoppedEventArgs e)
    {
        if (e.Exception is not null)
            PlaybackError?.Invoke(this, e.Exception);
    }

    public void Close()
    {
        lock (_gate) CloseLocked();
    }

    private void CloseLocked()
    {
        if (_player is not null)
        {
            try
            {
                if (_player.PlaybackState != PlaybackState.Stopped) _player.Stop();
            }
            catch (Exception ex) { _log?.LogDebug(ex, "Stopping the output failed"); }
            _player.PlaybackStopped -= OnPlaybackStopped;
            _player.Dispose();
            _player = null;
        }
        _device?.Dispose();
        _device = null;
        _format = null;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        Close();
        _notifications?.Dispose();
        _enumerator?.Dispose();
    }
}
