using System.Globalization;
using Microsoft.Extensions.Logging;
using MuurMusic.Core.Models;
using MuurMusic.Core.Sources;
using TagLib;

namespace MuurMusic.Core.Tags;

/// <summary>Result of reading a file's tags and audio properties.</summary>
public sealed record TagReadResult(Track Track, byte[]? Artwork, string? Lyrics, string? EmbeddedCueSheet);

/// <summary>
/// Changes to apply to one or more files (batch edit). For every property <c>null</c> means "leave unchanged";
/// an empty string (or 0 for numbers) clears the field.
/// </summary>
public sealed record TagEdit
{
    public string? Title { get; init; }
    public string? Artist { get; init; }
    public string? Album { get; init; }
    public string? AlbumArtist { get; init; }
    public string? Genre { get; init; }
    public string? Composer { get; init; }
    public int? Year { get; init; }
    public int? TrackNumber { get; init; }
    public int? TrackTotal { get; init; }
    public int? DiscNumber { get; init; }
    public int? DiscTotal { get; init; }
    public int? Bpm { get; init; }
    public string? Comment { get; init; }
    public string? Lyrics { get; init; }
    /// <summary>New front cover image (JPEG/PNG bytes).</summary>
    public byte[]? Artwork { get; init; }
    public bool RemoveArtwork { get; init; }
    public string? MusicBrainzRecordingId { get; init; }
    public string? MusicBrainzReleaseId { get; init; }

    public bool IsEmpty => this == new TagEdit();
}

/// <summary>Tag reading/writing through TagLib#.</summary>
public interface ITagService
{
    bool CanHandle(string path);
    /// <summary>Reads tags + properties; returns null when TagLib cannot open the file.</summary>
    TagReadResult? Read(string path);
    /// <summary>Applies <paramref name="edit"/> to the file (retries while the file is briefly locked).</summary>
    Task WriteAsync(string path, TagEdit edit, CancellationToken ct = default);
    string? ReadLyrics(string path);
    byte[]? ReadArtwork(string path);
}

public sealed class TagService(ILogger<TagService> logger) : ITagService
{
    public bool CanHandle(string path) => AudioFormats.TagLibExtensions.Contains(Path.GetExtension(path));

    public TagReadResult? Read(string path)
    {
        if (!CanHandle(path)) return null;
        try
        {
            using var file = TagLib.File.Create(path, ReadStyle.Average | ReadStyle.PictureLazy);
            var tag = file.Tag;
            var props = file.Properties;
            var fi = new FileInfo(path);
            var track = new Track
            {
                SourceUri = SourceUris.FromLocalPath(path),
                FilePath = fi.FullName,
                Folder = fi.DirectoryName,
                FileName = fi.Name,
                Title = Clean(tag.Title),
                Artist = Join(tag.Performers),
                Album = Clean(tag.Album),
                AlbumArtist = Join(tag.AlbumArtists),
                Genre = Join(tag.Genres),
                Composer = Join(tag.Composers),
                Year = tag.Year > 0 ? (int)tag.Year : null,
                TrackNumber = tag.Track > 0 ? (int)tag.Track : null,
                TrackTotal = tag.TrackCount > 0 ? (int)tag.TrackCount : null,
                DiscNumber = tag.Disc > 0 ? (int)tag.Disc : null,
                DiscTotal = tag.DiscCount > 0 ? (int)tag.DiscCount : null,
                Bpm = tag.BeatsPerMinute > 0 ? (int)tag.BeatsPerMinute : null,
                Comment = Clean(tag.Comment),
                HasLyrics = !string.IsNullOrWhiteSpace(tag.Lyrics),
                DurationMs = props is null ? 0 : (long)props.Duration.TotalMilliseconds,
                Bitrate = props?.AudioBitrate ?? 0,
                SampleRate = props?.AudioSampleRate ?? 0,
                BitDepth = props?.BitsPerSample ?? 0,
                Channels = props?.AudioChannels ?? 0,
                Codec = DetectCodec(path, props),
                Format = Path.GetExtension(path).TrimStart('.').ToLowerInvariant(),
                FileSize = fi.Length,
                FileModifiedMs = new DateTimeOffset(fi.LastWriteTimeUtc).ToUnixTimeMilliseconds(),
                ReplayGainTrackGain = NaNToNull(tag.ReplayGainTrackGain),
                ReplayGainTrackPeak = NaNToNull(tag.ReplayGainTrackPeak),
                ReplayGainAlbumGain = NaNToNull(tag.ReplayGainAlbumGain),
                ReplayGainAlbumPeak = NaNToNull(tag.ReplayGainAlbumPeak),
                MusicBrainzRecordingId = Clean(tag.MusicBrainzTrackId),
                MusicBrainzReleaseId = Clean(tag.MusicBrainzReleaseId),
                Rating = ReadRating(file)
            };
            if (track.Bitrate == 0 && track.DurationMs > 0) track.Bitrate = (int)(fi.Length * 8 / track.DurationMs);
            if (!AudioFormats.IsLosslessCodec(track.Codec)) track.BitDepth = 0;
            byte[]? art = null;
            var pics = tag.Pictures;
            if (pics is { Length: > 0 })
            {
                var pic = pics.FirstOrDefault(p => p.Type == PictureType.FrontCover) ?? pics[0];
                art = pic.Data?.Data is { Length: > 0 } d ? d : null;
            }
            return new TagReadResult(track, art, Clean(tag.Lyrics), ReadEmbeddedCue(file));
        }
        catch (Exception ex) when (ex is CorruptFileException or UnsupportedFormatException or IOException or UnauthorizedAccessException or ArgumentException or InvalidOperationException or IndexOutOfRangeException or OverflowException or NullReferenceException)
        {
            logger.LogDebug(ex, "TagLib could not read {Path}", path);
            return null;
        }
    }

    public string? ReadLyrics(string path)
    {
        if (!CanHandle(path)) return null;
        try
        {
            using var file = TagLib.File.Create(path, ReadStyle.None | ReadStyle.PictureLazy);
            return Clean(file.Tag.Lyrics);
        }
        catch (Exception ex) when (ex is CorruptFileException or UnsupportedFormatException or IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    public byte[]? ReadArtwork(string path)
    {
        if (!CanHandle(path)) return null;
        try
        {
            using var file = TagLib.File.Create(path, ReadStyle.None);
            var pics = file.Tag.Pictures;
            if (pics is not { Length: > 0 }) return null;
            var pic = pics.FirstOrDefault(p => p.Type == PictureType.FrontCover) ?? pics[0];
            return pic.Data?.Data;
        }
        catch (Exception ex) when (ex is CorruptFileException or UnsupportedFormatException or IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    public async Task WriteAsync(string path, TagEdit edit, CancellationToken ct = default)
    {
        if (!CanHandle(path)) throw new NotSupportedException($"Tag editing is not supported for {Path.GetExtension(path)} files.");
        for (var attempt = 0; ; attempt++)
        {
            try
            {
                WriteCore(path, edit);
                return;
            }
            catch (IOException) when (attempt < 5)
            {
                await Task.Delay(300, ct).ConfigureAwait(false);
            }
        }
    }

    private static void WriteCore(string path, TagEdit e)
    {
        using var file = TagLib.File.Create(path);
        EnsurePrimaryTag(file, path);
        var tag = file.Tag;
        if (e.Title is not null) tag.Title = NullIfEmpty(e.Title);
        if (e.Artist is not null) tag.Performers = Split(e.Artist);
        if (e.Album is not null) tag.Album = NullIfEmpty(e.Album);
        if (e.AlbumArtist is not null) tag.AlbumArtists = Split(e.AlbumArtist);
        if (e.Genre is not null) tag.Genres = Split(e.Genre);
        if (e.Composer is not null) tag.Composers = Split(e.Composer);
        if (e.Year is not null) tag.Year = (uint)Math.Max(0, e.Year.Value);
        if (e.TrackNumber is not null) tag.Track = (uint)Math.Max(0, e.TrackNumber.Value);
        if (e.TrackTotal is not null) tag.TrackCount = (uint)Math.Max(0, e.TrackTotal.Value);
        if (e.DiscNumber is not null) tag.Disc = (uint)Math.Max(0, e.DiscNumber.Value);
        if (e.DiscTotal is not null) tag.DiscCount = (uint)Math.Max(0, e.DiscTotal.Value);
        if (e.Bpm is not null) tag.BeatsPerMinute = (uint)Math.Max(0, e.Bpm.Value);
        if (e.Comment is not null) tag.Comment = NullIfEmpty(e.Comment);
        if (e.Lyrics is not null) tag.Lyrics = NullIfEmpty(e.Lyrics);
        if (e.MusicBrainzRecordingId is not null) tag.MusicBrainzTrackId = NullIfEmpty(e.MusicBrainzRecordingId);
        if (e.MusicBrainzReleaseId is not null) tag.MusicBrainzReleaseId = NullIfEmpty(e.MusicBrainzReleaseId);
        if (e.RemoveArtwork) tag.Pictures = Array.Empty<IPicture>();
        if (e.Artwork is { Length: > 0 })
        {
            var pic = new Picture(new ByteVector(e.Artwork))
            {
                Type = PictureType.FrontCover,
                MimeType = ArtworkCache.SniffMime(e.Artwork),
                Description = "Cover"
            };
            tag.Pictures = new IPicture[] { pic };
        }
        file.Save();
    }

    private static void EnsurePrimaryTag(TagLib.File file, string path)
    {
        var type = Path.GetExtension(path).ToLowerInvariant() switch
        {
            ".mp3" or ".mp2" or ".wav" or ".aif" or ".aiff" or ".dsf" => TagTypes.Id3v2,
            ".flac" or ".ogg" or ".oga" or ".opus" or ".spx" => TagTypes.Xiph,
            ".ape" or ".wv" or ".mpc" or ".mp+" or ".mpp" or ".tta" => TagTypes.Ape,
            ".m4a" or ".m4b" or ".mp4" or ".aac" or ".m4v" or ".3gp" => TagTypes.Apple,
            ".wma" or ".asf" => TagTypes.Asf,
            ".mkv" or ".mka" or ".webm" => TagTypes.Matroska,
            _ => TagTypes.None
        };
        if (type == TagTypes.None) return;
        try { file.GetTag(type, true); }
        catch (Exception ex) when (ex is NotSupportedException or InvalidOperationException or ArgumentException) { }
    }

    private static int ReadRating(TagLib.File file)
    {
        try
        {
            if (file.GetTag(TagTypes.Id3v2, false) is TagLib.Id3v2.Tag id3)
            {
                var popm = id3.GetFrames<TagLib.Id3v2.PopularimeterFrame>().FirstOrDefault();
                if (popm is not null && popm.Rating > 0)
                    return popm.Rating switch { < 32 => 1, < 96 => 2, < 160 => 3, < 224 => 4, _ => 5 };
            }
            if (file.GetTag(TagTypes.Xiph, false) is TagLib.Ogg.XiphComment xiph)
            {
                var r = xiph.GetFirstField("RATING");
                if (double.TryParse(r, NumberStyles.Float, CultureInfo.InvariantCulture, out var v) && v > 0)
                    return v <= 5 ? (int)Math.Round(v) : (int)Math.Clamp(Math.Round(v / 20.0), 1, 5);
            }
        }
        catch (Exception ex) when (ex is InvalidOperationException or ArgumentException) { }
        return 0;
    }

    private static string? ReadEmbeddedCue(TagLib.File file)
    {
        try
        {
            if (file.GetTag(TagTypes.Xiph, false) is TagLib.Ogg.XiphComment xiph)
            {
                var cue = xiph.GetFirstField("CUESHEET");
                if (!string.IsNullOrWhiteSpace(cue)) return cue;
            }
            if (file.GetTag(TagTypes.Ape, false) is TagLib.Ape.Tag ape)
            {
                var item = ape.GetItem("Cuesheet");
                if (item is not null && !string.IsNullOrWhiteSpace(item.ToString())) return item.ToString();
            }
        }
        catch (Exception ex) when (ex is InvalidOperationException or ArgumentException) { }
        return null;
    }

    internal static string DetectCodec(string path, Properties? props)
    {
        var fromExt = AudioFormats.CodecFromExtension(path);
        var desc = props?.Codecs?.Where(c => c is not null && c.MediaTypes.HasFlag(MediaTypes.Audio)).Select(c => c.Description).FirstOrDefault()?.ToLowerInvariant() ?? props?.Description?.ToLowerInvariant() ?? "";
        if (desc.Contains("alac")) return "ALAC";
        if (desc.Contains("opus")) return "Opus";
        if (desc.Contains("vorbis")) return "Vorbis";
        if (desc.Contains("flac")) return "FLAC";
        if (desc.Contains("wavpack")) return "WavPack";
        if (desc.Contains("monkey")) return "APE";
        if (desc.Contains("musepack")) return "Musepack";
        if (desc.Contains("windows media") && desc.Contains("lossless")) return "WMA Lossless";
        if (desc.Contains("layer 3")) return "MP3";
        if (desc.Contains("layer 2")) return "MP2";
        if (desc.Contains("aac") || desc.Contains("mpeg-4 audio")) return fromExt == "ALAC" ? "ALAC" : "AAC";
        return fromExt;
    }

    private static double? NaNToNull(double v) => double.IsNaN(v) || double.IsInfinity(v) ? null : v;
    private static string? Clean(string? s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim().TrimEnd('\0');
    private static string? Join(string[]? values)
    {
        if (values is null || values.Length == 0) return null;
        var v = string.Join("; ", values.Select(x => x?.Trim()).Where(x => !string.IsNullOrEmpty(x)).Distinct());
        return v.Length == 0 ? null : v;
    }
    private static string[] Split(string value) =>
        string.IsNullOrWhiteSpace(value) ? Array.Empty<string>() : value.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
    private static string? NullIfEmpty(string s) => string.IsNullOrWhiteSpace(s) ? null : s;
}
