using System.Net;
using System.Xml.Linq;
using Microsoft.Extensions.Logging;
using MuurMusic.Core.Discovery;
using MuurMusic.Core.Models;
using MuurMusic.Core.Sources;

namespace MuurMusic.Audio.Casting;

/// <summary>DLNA/UPnP MediaRenderer session over AVTransport + RenderingControl SOAP (no eventing; state polled once per second).</summary>
internal sealed class DlnaSession : ICastSession
{
    internal const string AvTransportType = "urn:schemas-upnp-org:service:AVTransport:1";
    internal const string RenderingControlType = "urn:schemas-upnp-org:service:RenderingControl:1";

    private readonly UpnpDevice _device;
    private readonly HttpClient _http;
    private readonly ILogger? _log;
    private readonly string _avTransportUrl;
    private readonly string? _renderingUrl;
    private Timer? _poll;
    private TimeSpan _position;
    private bool _playing;
    private bool _endedRaised;
    private bool _suppressEnded;
    private bool _polling;
    private bool _disposed;

    public DlnaSession(CastDeviceInfo device, UpnpDevice upnp, HttpClient http, ILogger? log)
    {
        Device = device;
        _device = upnp;
        _http = http;
        _log = log;
        _avTransportUrl = upnp.FindService("AVTransport")?.ControlUrl ?? throw new Core.Sources.SourceException($"{device.Name} has no AVTransport service.");
        _renderingUrl = upnp.FindService("RenderingControl")?.ControlUrl;
    }

    public CastDeviceInfo Device { get; }
    public TimeSpan Position => _position;
    public bool IsPlaying => _playing;
    public event EventHandler? StateChanged;
    public event EventHandler? TrackEnded;
    public event EventHandler? Disconnected;

    public Task ConnectAsync(CancellationToken ct)
    {
        _poll = new Timer(_ => _ = PollAsync(), null, TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(1));
        return Task.CompletedTask;
    }

    private Task<XElement> AvAsync(string action, params (string, string)[] args) =>
        Ssdp.SoapAsync(_http, _avTransportUrl, AvTransportType, action, args);

    public async Task LoadTrackAsync(Track track, Uri mediaUri, string mime, Uri? artUri, TimeSpan startAt, bool autoPlay, CancellationToken ct)
    {
        _endedRaised = false;
        _suppressEnded = true;
        try
        {
            var didl = Didl.BuildItem(mediaUri.AbsoluteUri, mime, track.DisplayTitle, track.DisplayArtist,
                string.IsNullOrWhiteSpace(track.Album) ? null : track.Album, artUri?.AbsoluteUri, track.Duration, track.FileSize);
            await AvAsync("SetAVTransportURI", ("InstanceID", "0"), ("CurrentURI", mediaUri.AbsoluteUri), ("CurrentURIMetaData", didl)).ConfigureAwait(false);
            if (autoPlay) await AvAsync("Play", ("InstanceID", "0"), ("Speed", "1")).ConfigureAwait(false);
            if (startAt > TimeSpan.FromSeconds(1)) await SeekAsync(startAt, ct).ConfigureAwait(false);
            _position = startAt;
            _playing = autoPlay;
            StateChanged?.Invoke(this, EventArgs.Empty);
        }
        finally
        {
            // The renderer reports STOPPED while it switches URIs; ignore that transition.
            _ = Task.Delay(2000).ContinueWith(_ => _suppressEnded = false);
        }
    }

    public Task PlayAsync(CancellationToken ct) => AvAsync("Play", ("InstanceID", "0"), ("Speed", "1"));
    public Task PauseAsync(CancellationToken ct) => AvAsync("Pause", ("InstanceID", "0"));

    public async Task StopAsync(CancellationToken ct)
    {
        _suppressEnded = true;
        try { await AvAsync("Stop", ("InstanceID", "0")).ConfigureAwait(false); }
        finally { _ = Task.Delay(2000).ContinueWith(_ => _suppressEnded = false); }
    }

    public async Task SeekAsync(TimeSpan position, CancellationToken ct)
    {
        _position = position;
        await AvAsync("Seek", ("InstanceID", "0"), ("Unit", "REL_TIME"), ("Target", FormatTime(position))).ConfigureAwait(false);
    }

    public async Task SetVolumeAsync(double volume, CancellationToken ct)
    {
        if (_renderingUrl is null) return;
        var v = (int)Math.Round(Math.Clamp(volume, 0, 1) * 100);
        await Ssdp.SoapAsync(_http, _renderingUrl, RenderingControlType, "SetVolume", new[] { ("InstanceID", "0"), ("Channel", "Master"), ("DesiredVolume", v.ToString()) }, ct).ConfigureAwait(false);
    }

    public async Task SetMutedAsync(bool muted, CancellationToken ct)
    {
        if (_renderingUrl is null) return;
        await Ssdp.SoapAsync(_http, _renderingUrl, RenderingControlType, "SetMute", new[] { ("InstanceID", "0"), ("Channel", "Master"), ("DesiredMute", muted ? "1" : "0") }, ct).ConfigureAwait(false);
    }

    private async Task PollAsync()
    {
        if (_polling || _disposed) return;
        _polling = true;
        try
        {
            var info = await AvAsync("GetTransportInfo", ("InstanceID", "0")).ConfigureAwait(false);
            var state = info.Element("CurrentTransportState")?.Value ?? "";
            var playing = state == "PLAYING";
            var changed = playing != _playing;
            _playing = playing;
            if (state is "PLAYING" or "PAUSED_PLAYBACK" or "TRANSITIONING")
            {
                try
                {
                    var pos = await AvAsync("GetPositionInfo", ("InstanceID", "0")).ConfigureAwait(false);
                    if (TryParseTime(pos.Element("RelTime")?.Value, out var p))
                    {
                        changed |= (p - _position).Duration() > TimeSpan.FromSeconds(2);
                        _position = p;
                    }
                }
                catch (Exception ex) { _log?.LogDebug(ex, "GetPositionInfo failed on {Device}", Device.Name); }
            }
            if (state == "STOPPED" && !_suppressEnded && !_endedRaised)
            {
                _endedRaised = true;
                TrackEnded?.Invoke(this, EventArgs.Empty);
            }
            if (changed) StateChanged?.Invoke(this, EventArgs.Empty);
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or System.Xml.XmlException or InvalidOperationException)
        {
            _log?.LogInformation(ex, "DLNA renderer {Device} unreachable", Device.Name);
            if (!_disposed) Disconnected?.Invoke(this, EventArgs.Empty);
        }
        catch (Exception ex) { _log?.LogDebug(ex, "DLNA poll failed"); }
        finally { _polling = false; }
    }

    internal static string FormatTime(TimeSpan t) => $"{(int)t.TotalHours}:{t.Minutes:00}:{t.Seconds:00}";

    internal static bool TryParseTime(string? value, out TimeSpan result)
    {
        result = TimeSpan.Zero;
        if (string.IsNullOrWhiteSpace(value)) return false;
        var parts = value.Split(':');
        if (parts.Length != 3) return false;
        if (!int.TryParse(parts[0], out var h) || !int.TryParse(parts[1], out var m)) return false;
        if (!double.TryParse(parts[2], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var s)) return false;
        result = new TimeSpan(h, m, 0) + TimeSpan.FromSeconds(s);
        return true;
    }

    public async ValueTask DisposeAsync()
    {
        _disposed = true;
        _poll?.Dispose();
        try { await AvAsync("Stop", ("InstanceID", "0")).ConfigureAwait(false); }
        catch (Exception ex) { _log?.LogDebug(ex, "Stopping DLNA renderer failed"); }
    }
}
