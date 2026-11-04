using MuurMusic.Core.Models;

namespace MuurMusic.Audio.Casting;

public enum CastTransport { Chromecast, Dlna }

/// <summary>A discovered cast target (Chromecast or DLNA MediaRenderer).</summary>
public sealed record CastDeviceInfo(string Id, string Name, CastTransport Transport, string? Model)
{
    /// <summary>ChromecastReceiver or UpnpDevice, depending on <see cref="Transport"/>.</summary>
    internal object? Native { get; init; }
    internal string? Host { get; init; }
}

/// <summary>One connected cast device.</summary>
internal interface ICastSession : IAsyncDisposable
{
    CastDeviceInfo Device { get; }
    TimeSpan Position { get; }
    bool IsPlaying { get; }
    Task ConnectAsync(CancellationToken ct);
    Task LoadTrackAsync(Track track, Uri mediaUri, string mime, Uri? artUri, TimeSpan startAt, bool autoPlay, CancellationToken ct);
    Task PlayAsync(CancellationToken ct);
    Task PauseAsync(CancellationToken ct);
    Task StopAsync(CancellationToken ct);
    Task SeekAsync(TimeSpan position, CancellationToken ct);
    Task SetVolumeAsync(double volume, CancellationToken ct);
    Task SetMutedAsync(bool muted, CancellationToken ct);
    /// <summary>Position or play state changed (polled or pushed).</summary>
    event EventHandler? StateChanged;
    /// <summary>The device finished the current media by itself.</summary>
    event EventHandler? TrackEnded;
    event EventHandler? Disconnected;
}
