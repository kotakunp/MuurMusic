using System.Runtime.InteropServices;
using Microsoft.Extensions.Logging;
using MuurMusic.Core.Models;
using Windows.Media;
using Windows.Media.Playback;
using Windows.Storage.Streams;

using MuurMusic.Audio.Playback;

namespace MuurMusic.Audio.Smtc;

/// <summary>Actions the system transport controls can ask the player to perform.</summary>
public enum SmtcCommand { Play, Pause, Stop, Next, Previous, Seek }

/// <summary>
/// Integrates with Windows System Media Transport Controls (media keys, lock screen, volume overlay). Obtained via
/// ISystemMediaTransportControlsInterop.GetForWindow for the app's HWND (the activation factory implements the interop
/// interface; GetForWindow is vtable slot 6). All calls are no-ops until <see cref="Initialize"/> succeeds; failures are
/// logged and never thrown.
/// </summary>
public sealed unsafe class SmtcService : IDisposable
{
    private static readonly Guid InteropIid = new("DDB0472D-C911-4A1F-86D9-DC3D71A95F5A");

    [DllImport("combase.dll")] private static extern int WindowsCreateString(IntPtr s, int length, out IntPtr hstr);
    [DllImport("combase.dll")] private static extern int WindowsDeleteString(IntPtr hstr);
    [DllImport("combase.dll")] private static extern int RoGetActivationFactory(IntPtr hstr, [In] ref Guid iid, out IntPtr factory);

    private readonly ILogger<SmtcService>? _log;
    private SystemMediaTransportControls? _smtc;
    private SystemMediaTransportControlsDisplayUpdater? _updater;
    private SystemMediaTransportControlsTimelineProperties _timeline = new();
    private bool _disposed;

    public SmtcService(ILogger<SmtcService>? log = null) => _log = log;

    public bool IsAvailable => _smtc is not null;

    /// <summary>Raised on a background thread when a transport button is pressed or the timeline is scrubbed.</summary>
    public event EventHandler<SmtcCommand>? Command;
    public event EventHandler<TimeSpan>? SeekRequested;
    public event EventHandler<bool>? ShuffleChangeRequested;
    public event EventHandler<RepeatMode>? RepeatChangeRequested;
    public event EventHandler<double>? PlaybackRateChangeRequested;

    /// <summary>Binds SMTC to the main window. Safe to call once at startup; a failure only disables SMTC.</summary>
    public void Initialize(IntPtr windowHandle)
    {
        if (_smtc is not null || windowHandle == IntPtr.Zero) return;
        IntPtr hstr = IntPtr.Zero, factory = IntPtr.Zero, raw = IntPtr.Zero;
        try
        {
            const string name = "Windows.Media.SystemMediaTransportControls";
            raw = Marshal.StringToHGlobalUni(name);
            if (WindowsCreateString(raw, name.Length, out hstr) != 0) return;
            var iid = InteropIid;
            if (RoGetActivationFactory(hstr, ref iid, out factory) != 0 || factory == IntPtr.Zero) return;
            var vtbl = *(IntPtr**)factory;
            var getForWindow = (delegate* unmanaged[Stdcall]<IntPtr, IntPtr, Guid*, IntPtr*, int>)vtbl[6];
            var riid = typeof(SystemMediaTransportControls).GUID;
            IntPtr ptr;
            if (getForWindow(factory, windowHandle, &riid, &ptr) != 0 || ptr == IntPtr.Zero) return;
            _smtc = SystemMediaTransportControls.FromAbi(ptr);
            _smtc.IsEnabled = true;
            _smtc.IsPlayEnabled = true;
            _smtc.IsPauseEnabled = true;
            _smtc.IsStopEnabled = true;
            _smtc.IsNextEnabled = true;
            _smtc.IsPreviousEnabled = true;
            _smtc.PlaybackStatus = MediaPlaybackStatus.Stopped;
            _smtc.ButtonPressed += OnButtonPressed;
            _smtc.PlaybackPositionChangeRequested += (_, e) => SeekRequested?.Invoke(this, e.RequestedPlaybackPosition);
            _smtc.ShuffleEnabledChangeRequested += (_, e) => ShuffleChangeRequested?.Invoke(this, e.RequestedShuffleEnabled);
            _smtc.AutoRepeatModeChangeRequested += (_, e) => RepeatChangeRequested?.Invoke(this, e.RequestedAutoRepeatMode switch
            {
                MediaPlaybackAutoRepeatMode.Track => RepeatMode.One,
                MediaPlaybackAutoRepeatMode.List => RepeatMode.All,
                _ => RepeatMode.Off
            });
            _smtc.PlaybackRateChangeRequested += (_, e) => PlaybackRateChangeRequested?.Invoke(this, e.RequestedPlaybackRate);
            _updater = _smtc.DisplayUpdater;
            _updater.Type = MediaPlaybackType.Music;
            _updater.Update();
            _log?.LogInformation("System Media Transport Controls bound");
        }
        catch (Exception ex)
        {
            _log?.LogWarning(ex, "System Media Transport Controls unavailable");
            _smtc = null;
            _updater = null;
        }
        finally
        {
            if (hstr != IntPtr.Zero) WindowsDeleteString(hstr);
            if (factory != IntPtr.Zero) Marshal.Release(factory);
            if (raw != IntPtr.Zero) Marshal.FreeHGlobal(raw);
        }
    }

    private void OnButtonPressed(SystemMediaTransportControls sender, SystemMediaTransportControlsButtonPressedEventArgs e)
    {
        var cmd = e.Button switch
        {
            SystemMediaTransportControlsButton.Play => SmtcCommand.Play,
            SystemMediaTransportControlsButton.Pause => SmtcCommand.Pause,
            SystemMediaTransportControlsButton.Stop => SmtcCommand.Stop,
            SystemMediaTransportControlsButton.Next => SmtcCommand.Next,
            SystemMediaTransportControlsButton.Previous => SmtcCommand.Previous,
            _ => (SmtcCommand?)null
        };
        if (cmd is { } c) Command?.Invoke(this, c);
    }

    /// <summary>Updates title/artist/album/artwork for the current track (null clears).</summary>
    public void UpdateTrack(Track? track, string? artworkFilePath)
    {
        var updater = _updater;
        if (updater is null) return;
        try
        {
            if (track is null)
            {
                updater.ClearAll();
                updater.Type = MediaPlaybackType.Music;
            }
            else
            {
                updater.Type = MediaPlaybackType.Music;
                var music = updater.MusicProperties;
                music.Title = track.DisplayTitle;
                music.Artist = track.DisplayArtist;
                music.AlbumTitle = string.IsNullOrWhiteSpace(track.Album) ? "" : track.Album!;
                music.AlbumArtist = string.IsNullOrWhiteSpace(track.AlbumArtist) ? "" : track.AlbumArtist!;
                music.TrackNumber = (uint)(track.TrackNumber ?? 0);
                music.AlbumTrackCount = (uint)(track.TrackTotal ?? 0);
                updater.Thumbnail = artworkFilePath is not null && File.Exists(artworkFilePath)
                    ? RandomAccessStreamReference.CreateFromUri(new Uri(artworkFilePath))
                    : null;
            }
            updater.Update();
        }
        catch (Exception ex) { _log?.LogDebug(ex, "SMTC metadata update failed"); }
    }

    public void UpdatePlaybackStatus(PlayerState state, bool buffering = false)
    {
        if (_smtc is null) return;
        try
        {
            _smtc.PlaybackStatus = state switch
            {
                PlayerState.Playing => MediaPlaybackStatus.Playing,
                PlayerState.Paused => MediaPlaybackStatus.Paused,
                PlayerState.Buffering => MediaPlaybackStatus.Changing,
                _ => MediaPlaybackStatus.Stopped
            };
        }
        catch (Exception ex) { _log?.LogDebug(ex, "SMTC status update failed"); }
    }

    /// <summary>Updates the seek bar. Call on track change and after seeks (SMTC throttles internally if called often).</summary>
    public void UpdatePosition(TimeSpan position, TimeSpan duration)
    {
        if (_smtc is null) return;
        try
        {
            if (duration <= TimeSpan.Zero) return;
            _timeline.StartTime = TimeSpan.Zero;
            _timeline.MinSeekTime = TimeSpan.Zero;
            _timeline.EndTime = duration;
            _timeline.MaxSeekTime = duration;
            _timeline.Position = position < duration ? position : duration;
            _smtc.UpdateTimelineProperties(_timeline);
        }
        catch (Exception ex) { _log?.LogDebug(ex, "SMTC timeline update failed"); }
    }

    public void UpdateModes(bool shuffle, RepeatMode repeat)
    {
        if (_smtc is null) return;
        try
        {
            _smtc.ShuffleEnabled = shuffle;
            _smtc.AutoRepeatMode = repeat switch
            {
                RepeatMode.One => MediaPlaybackAutoRepeatMode.Track,
                RepeatMode.All => MediaPlaybackAutoRepeatMode.List,
                _ => MediaPlaybackAutoRepeatMode.None
            };
        }
        catch (Exception ex) { _log?.LogDebug(ex, "SMTC mode update failed"); }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        if (_smtc is not null)
        {
            try
            {
                _smtc.IsEnabled = false;
                _smtc.ButtonPressed -= OnButtonPressed;
            }
            catch (Exception ex) { _log?.LogDebug(ex, "SMTC teardown failed"); }
        }
        _smtc = null;
        _updater = null;
    }
}
