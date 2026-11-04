using MuurMusic.Core.Models;
using MuurMusic.Core.Settings;

namespace MuurMusic.Audio.Dsp;

/// <summary>ReplayGain 2.0 gain computation (track/album mode, preamp, untagged gain, clipping prevention from peak tags).</summary>
public static class ReplayGain
{
    /// <summary>Returns the linear gain for <paramref name="track"/>.</summary>
    public static float LinearGain(Track track, ReplayGainMode mode, double preampDb, double untaggedDb, bool preventClipping)
    {
        if (mode == ReplayGainMode.Off) return 1f;
        double? gain, peak;
        if (mode == ReplayGainMode.Album)
        {
            gain = track.ReplayGainAlbumGain ?? track.ReplayGainTrackGain;
            peak = track.ReplayGainAlbumGain.HasValue ? track.ReplayGainAlbumPeak : track.ReplayGainTrackPeak;
        }
        else
        {
            gain = track.ReplayGainTrackGain ?? track.ReplayGainAlbumGain;
            peak = track.ReplayGainTrackGain.HasValue ? track.ReplayGainTrackPeak : track.ReplayGainAlbumPeak;
        }
        var db = (gain ?? untaggedDb) + preampDb;
        var linear = Math.Pow(10, db / 20);
        if (preventClipping && gain.HasValue && peak is > 0)
            linear = Math.Min(linear, 1.0 / peak.Value);
        return (float)linear;
    }
}
