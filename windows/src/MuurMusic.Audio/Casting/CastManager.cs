using System.Net;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Extensions.Logging;
using MuurMusic.Core.Discovery;
using MuurMusic.Core.Models;
using MuurMusic.Core.Sources;
using MuurMusic.Core.Tags;
using Sharpcaster;
using Sharpcaster.Models;

namespace MuurMusic.Audio.Casting;

/// <summary>
/// Discovery (Chromecast via mDNS, DLNA renderers via SSDP) and playback on a remote device. Track bytes are served to the
/// device by an embedded HTTP server (<see cref="LocalHttpServer"/>) so every source — cloud, FTP, SFTP, ZIP — plays anywhere.
/// </summary>
public interface ICastManager : IAsyncDisposable
{
    bool IsActive { get; }
    CastDeviceInfo? ActiveDevice { get; }
    TimeSpan Position { get; }
    bool IsPlaying { get; }
    /// <summary>A device connected or disconnected.</summary>
    event EventHandler? ActiveDeviceChanged;
    /// <summary>Position or play state of the active session changed.</summary>
    event EventHandler? SessionStateChanged;
    /// <summary>The device finished the current track by itself.</summary>
    event EventHandler? SessionTrackEnded;
    /// <summary>The active session dropped unexpectedly.</summary>
    event EventHandler? SessionLost;

    /// <summary>Searches the LAN for Chromecasts and DLNA renderers.</summary>
    Task<IReadOnlyList<CastDeviceInfo>> DiscoverAsync(TimeSpan? timeout = null, CancellationToken ct = default);
    Task ConnectAsync(CastDeviceInfo device, CancellationToken ct = default);
    Task DisconnectAsync(CancellationToken ct = default);

    Task LoadTrackAsync(Track track, TimeSpan startAt, bool autoPlay = true, CancellationToken ct = default);
    Task PlayAsync(CancellationToken ct = default);
    Task PauseAsync(CancellationToken ct = default);
    Task StopAsync(CancellationToken ct = default);
    Task SeekAsync(TimeSpan position, CancellationToken ct = default);
    Task SetVolumeAsync(double volume, CancellationToken ct = default);
    Task SetMutedAsync(bool muted, CancellationToken ct = default);
}

public sealed class CastManager : ICastManager
{
    private readonly IHttpClientFactory _httpFactory;
    private readonly ISourceManager _sources;
    private readonly IArtworkCache _artwork;
    private readonly LocalHttpServer _server;
    private readonly ILoggerFactory _loggerFactory;
    private readonly ILogger<CastManager> _log;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private ICastSession? _session;
    private bool _disposed;

    public CastManager(IHttpClientFactory httpFactory, ISourceManager sources, IArtworkCache artwork, LocalHttpServer server,
        ILoggerFactory loggerFactory)
    {
        _httpFactory = httpFactory;
        _sources = sources;
        _artwork = artwork;
        _server = server;
        _loggerFactory = loggerFactory;
        _log = loggerFactory.CreateLogger<CastManager>();
    }

    public bool IsActive => _session is not null;
    public CastDeviceInfo? ActiveDevice => _session?.Device;
    public TimeSpan Position => _session?.Position ?? TimeSpan.Zero;
    public bool IsPlaying => _session?.IsPlaying ?? false;

    public event EventHandler? ActiveDeviceChanged;
    public event EventHandler? SessionStateChanged;
    public event EventHandler? SessionTrackEnded;
    public event EventHandler? SessionLost;

    public async Task<IReadOnlyList<CastDeviceInfo>> DiscoverAsync(TimeSpan? timeout = null, CancellationToken ct = default)
    {
        var duration = timeout ?? TimeSpan.FromSeconds(4);
        var results = new List<CastDeviceInfo>();
        var chromecasts = Task.Run(async () =>
        {
            try
            {
                using var locator = new ChromecastLocator(_loggerFactory.CreateLogger<ChromecastLocator>());
                var found = await locator.FindReceiversAsync(duration, null, null).WaitAsync(ct).ConfigureAwait(false);
                return found.Select(r => new CastDeviceInfo($"cc:{r.DeviceUri.Host}:{r.Port}", r.Name, CastTransport.Chromecast, r.Model) { Native = r, Host = r.DeviceUri.Host }).ToList();
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                _log.LogDebug(ex, "Chromecast discovery failed");
                return new List<CastDeviceInfo>();
            }
        }, ct);
        var renderers = Task.Run(async () =>
        {
            var list = new List<CastDeviceInfo>();
            try
            {
                var http = _httpFactory.CreateClient(HttpClientNames.Default);
                var responses = await Ssdp.SearchAsync(Ssdp.MediaRenderer, duration, ct).ConfigureAwait(false);
                foreach (var r in responses)
                {
                    ct.ThrowIfCancellationRequested();
                    try
                    {
                        var device = await Ssdp.GetDeviceAsync(http, r.Location, ct).ConfigureAwait(false);
                        if (device.FindService("AVTransport") is null) continue;
                        list.Add(new CastDeviceInfo($"dlna:{device.Udn}", device.FriendlyName, CastTransport.Dlna, device.ModelName) { Native = device, Host = new Uri(device.Location).Host });
                    }
                    catch (Exception ex) when (ex is not OperationCanceledException) { _log.LogDebug(ex, "Reading {Location} failed", r.Location); }
                }
            }
            catch (OperationCanceledException) { }
            catch (Exception ex) { _log.LogDebug(ex, "DLNA discovery failed"); }
            return list;
        }, ct);
        foreach (var batch in await Task.WhenAll(chromecasts, renderers).ConfigureAwait(false)) results.AddRange(batch);
        return results;
    }

    public async Task ConnectAsync(CastDeviceInfo device, CancellationToken ct = default)
    {
        await DisconnectAsync(ct).ConfigureAwait(false);
        _server.EnsureStarted();
        ICastSession session = device.Transport switch
        {
            CastTransport.Chromecast => new ChromecastSession(device, (ChromecastReceiver)device.Native!, _loggerFactory),
            _ => new DlnaSession(device, (UpnpDevice)device.Native!, _httpFactory.CreateClient(HttpClientNames.Default), _loggerFactory.CreateLogger<DlnaSession>())
        };
        await session.ConnectAsync(ct).ConfigureAwait(false);
        session.StateChanged += (_, _) => SessionStateChanged?.Invoke(this, EventArgs.Empty);
        session.TrackEnded += (_, _) => SessionTrackEnded?.Invoke(this, EventArgs.Empty);
        session.Disconnected += (_, _) => _ = OnSessionDisconnectedAsync(session);
        _session = session;
        _log.LogInformation("Casting to {Device} ({Transport})", device.Name, device.Transport);
        ActiveDeviceChanged?.Invoke(this, EventArgs.Empty);
    }

    private async Task OnSessionDisconnectedAsync(ICastSession session)
    {
        if (!ReferenceEquals(_session, session)) return;
        _session = null;
        SessionLost?.Invoke(this, EventArgs.Empty);
        ActiveDeviceChanged?.Invoke(this, EventArgs.Empty);
        try { await session.DisposeAsync().ConfigureAwait(false); } catch (Exception ex) { _log.LogDebug(ex, "Session dispose failed"); }
    }

    public async Task DisconnectAsync(CancellationToken ct = default)
    {
        var session = Interlocked.Exchange(ref _session, null);
        if (session is null) return;
        try { await session.StopAsync(ct).ConfigureAwait(false); } catch (Exception ex) { _log.LogDebug(ex, "Cast stop failed"); }
        try { await session.DisposeAsync().ConfigureAwait(false); } catch (Exception ex) { _log.LogDebug(ex, "Session dispose failed"); }
        ActiveDeviceChanged?.Invoke(this, EventArgs.Empty);
    }

    public async Task LoadTrackAsync(Track track, TimeSpan startAt, bool autoPlay = true, CancellationToken ct = default)
    {
        var session = _session ?? throw new InvalidOperationException("No cast device connected.");
        var key = Convert.ToHexStringLower(SHA1.HashData(Encoding.UTF8.GetBytes(track.Key)));
        var remote = session.Device.Host is { } host && IPAddress.TryParse(host, out var ip) ? ip : null;
        // Resolve per request so expiring cloud URLs and tokens are renewed for every device read.
        _server.Register(key, track.MimeType(), async (offset, c) =>
        {
            var location = await _sources.ResolveTrackAsync(track, c).ConfigureAwait(false);
            var http = _httpFactory.CreateClient(HttpClientNames.Default);
            return await location.OpenReadAsync(http, offset, c).ConfigureAwait(false);
        }, () => track.FileSize);
        var mediaUri = _server.UrlFor(key, string.IsNullOrEmpty(track.FileName) ? "audio" : track.FileName, remote);
        Uri? artUri = null;
        if (_artwork.GetPath(track.ArtworkHash) is { } artPath)
        {
            var artKey = "art-" + track.ArtworkHash;
            var head = File.ReadAllBytes(artPath);
            if (head.Length > 16) Array.Resize(ref head, 16);
            _server.RegisterFile(artKey, artPath, ArtworkCache.SniffMime(head) ?? "image/jpeg");
            artUri = _server.UrlFor(artKey, "cover.jpg", remote);
        }
        await session.LoadTrackAsync(track, mediaUri, track.MimeType(), artUri, startAt, autoPlay, ct).ConfigureAwait(false);
    }

    private ICastSession Session => _session ?? throw new InvalidOperationException("No cast device connected.");

    public Task PlayAsync(CancellationToken ct = default) => Session.PlayAsync(ct);
    public Task PauseAsync(CancellationToken ct = default) => Session.PauseAsync(ct);
    public Task StopAsync(CancellationToken ct = default) => Session.StopAsync(ct);
    public Task SeekAsync(TimeSpan position, CancellationToken ct = default) => Session.SeekAsync(position, ct);
    public Task SetVolumeAsync(double volume, CancellationToken ct = default) => Session.SetVolumeAsync(volume, ct);
    public Task SetMutedAsync(bool muted, CancellationToken ct = default) => Session.SetMutedAsync(muted, ct);

    public async ValueTask DisposeAsync()
    {
        if (_disposed) return;
        _disposed = true;
        await DisconnectAsync(default).ConfigureAwait(false);
        _gate.Dispose();
    }
}

internal static class CastTrackExtensions
{
    /// <summary>MIME type for the cast stream; defaults by file extension, audio/flac as last resort.</summary>
    public static string MimeType(this Track track) =>
        AudioFormats.MimeTypeFromExtension(string.IsNullOrEmpty(track.FileName) ? track.SourceUri : track.FileName) is { Length: > 0 } m ? m : "audio/flac";
}
