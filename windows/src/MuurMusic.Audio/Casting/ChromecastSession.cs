using Microsoft.Extensions.Logging;
using Sharpcaster;
using Sharpcaster.Models;
using Sharpcaster.Models.Media;
using Track = MuurMusic.Core.Models.Track;

namespace MuurMusic.Audio.Casting;

/// <summary>Chromecast session via Sharpcaster (Default Media Receiver, app CC1AD845). Position/state polled once per second plus pushed status updates.</summary>
internal sealed class ChromecastSession : ICastSession
{
    private const string DefaultMediaReceiverAppId = "CC1AD845";
    private readonly ChromecastReceiver _receiver;
    private readonly ILoggerFactory? _loggerFactory;
    private readonly ILogger? _log;
    private ChromecastClient? _client;
    private Timer? _poll;
    private TimeSpan _position;
    private bool _playing;
    private bool _endedRaised;
    private bool _polling;
    private int _connected;

    public ChromecastSession(CastDeviceInfo device, ChromecastReceiver receiver, ILoggerFactory? loggerFactory)
    {
        Device = device;
        _receiver = receiver;
        _loggerFactory = loggerFactory;
        _log = loggerFactory?.CreateLogger<ChromecastSession>();
    }

    public CastDeviceInfo Device { get; }
    public TimeSpan Position => _position;
    public bool IsPlaying => _playing;
    public event EventHandler? StateChanged;
    public event EventHandler? TrackEnded;
    public event EventHandler? Disconnected;

    public async Task ConnectAsync(CancellationToken ct)
    {
        var client = _loggerFactory is null ? new ChromecastClient() : new ChromecastClient(_loggerFactory.CreateLogger<ChromecastClient>());
        client.Disconnected += OnDisconnected;
        client.MediaChannel.StatusChanged += OnStatusChanged;
        await client.ConnectChromecast(_receiver).WaitAsync(ct).ConfigureAwait(false);
        await client.LaunchApplicationAsync(DefaultMediaReceiverAppId, true).WaitAsync(ct).ConfigureAwait(false);
        _client = client;
        Interlocked.Exchange(ref _connected, 1);
        _poll = new Timer(_ => _ = PollAsync(), null, TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(1));
    }

    public async Task LoadTrackAsync(Track track, Uri mediaUri, string mime, Uri? artUri, TimeSpan startAt, bool autoPlay, CancellationToken ct)
    {
        var client = Client;
        _endedRaised = false;
        var media = new Media
        {
            ContentUrl = mediaUri.AbsoluteUri,
            ContentId = mediaUri.AbsoluteUri,
            ContentType = mime,
            StreamType = StreamType.Buffered,
            Duration = track.Duration > TimeSpan.Zero ? track.Duration.TotalSeconds : null,
            Metadata = new MusicTrackMetadata
            {
                SongName = track.DisplayTitle,
                Artist = track.DisplayArtist,
                AlbumName = string.IsNullOrWhiteSpace(track.Album) ? null : track.Album,
                AlbumArtist = track.AlbumArtist,
                TrackNumber = track.TrackNumber,
                Images = artUri is null ? null : new[] { new Image { Url = artUri.AbsoluteUri } }
            }
        };
        await client.MediaChannel.LoadAsync(media, autoPlay, Array.Empty<int>()).WaitAsync(ct).ConfigureAwait(false);
        if (startAt > TimeSpan.FromSeconds(1))
            await client.MediaChannel.SeekAsync(startAt.TotalSeconds).WaitAsync(ct).ConfigureAwait(false);
        _position = startAt;
        _playing = autoPlay;
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    public Task PlayAsync(CancellationToken ct) => Client.MediaChannel.PlayAsync().WaitAsync(ct);
    public Task PauseAsync(CancellationToken ct) => Client.MediaChannel.PauseAsync().WaitAsync(ct);
    public Task StopAsync(CancellationToken ct) => Client.MediaChannel.StopAsync().WaitAsync(ct);
    public async Task SeekAsync(TimeSpan position, CancellationToken ct)
    {
        _position = position;
        await Client.MediaChannel.SeekAsync(position.TotalSeconds).WaitAsync(ct).ConfigureAwait(false);
    }

    public Task SetVolumeAsync(double volume, CancellationToken ct) => Client.MediaChannel.SetVolumeAsync(Math.Clamp(volume, 0, 1)).WaitAsync(ct);
    public Task SetMutedAsync(bool muted, CancellationToken ct) => Client.MediaChannel.SetMuteAsync(muted).WaitAsync(ct);

    private ChromecastClient Client => _client ?? throw new InvalidOperationException("Not connected.");

    private void OnStatusChanged(object? sender, MediaStatus status) => ApplyStatus(status);

    private async Task PollAsync()
    {
        if (_polling || _client is null || _connected == 0) return;
        _polling = true;
        try
        {
            var status = await _client.MediaChannel.GetMediaStatusAsync().ConfigureAwait(false);
            if (status is not null) ApplyStatus(status);
        }
        catch (Exception ex) { _log?.LogDebug(ex, "Chromecast status poll failed"); }
        finally { _polling = false; }
    }

    private void ApplyStatus(MediaStatus status)
    {
        var playing = status.PlayerState == PlayerStateType.Playing;
        var position = TimeSpan.FromSeconds(Math.Max(0, status.CurrentTime));
        var changed = playing != _playing || (position - _position).Duration() > TimeSpan.FromSeconds(2);
        _playing = playing;
        if (playing || status.PlayerState == PlayerStateType.Paused) _position = position;
        if (status.PlayerState == PlayerStateType.Idle && string.Equals(status.IdleReason, "FINISHED", StringComparison.OrdinalIgnoreCase) && !_endedRaised)
        {
            _endedRaised = true;
            _playing = false;
            TrackEnded?.Invoke(this, EventArgs.Empty);
        }
        if (changed) StateChanged?.Invoke(this, EventArgs.Empty);
    }

    private void OnDisconnected(object? sender, EventArgs e)
    {
        if (Interlocked.Exchange(ref _connected, 0) == 1)
            Disconnected?.Invoke(this, EventArgs.Empty);
    }

    public async ValueTask DisposeAsync()
    {
        _poll?.Dispose();
        var client = Interlocked.Exchange(ref _client, null);
        if (client is not null)
        {
            client.Disconnected -= OnDisconnected;
            try { await client.DisconnectAsync().ConfigureAwait(false); } catch (Exception ex) { _log?.LogDebug(ex, "Chromecast disconnect failed"); }
            try { await client.Dispose().ConfigureAwait(false); } catch (Exception ex) { _log?.LogDebug(ex, "Chromecast dispose failed"); }
        }
    }
}
