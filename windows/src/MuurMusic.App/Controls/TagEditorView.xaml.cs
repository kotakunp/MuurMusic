using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using MuurMusic.App.Services;
using MuurMusic.Core.Metadata;
using MuurMusic.Core.Models;
using MuurMusic.Core.Tags;
using Windows.Storage;

namespace MuurMusic.App.Controls;

/// <summary>Tag editor form shared by the tag editor dialog (single and multi-track batch mode).</summary>
public sealed partial class TagEditorView : UserControl
{
    public sealed record MbResult(string Display, string Detail, MusicBrainzMatch Match);

    private readonly IReadOnlyList<Track> _tracks;
    private readonly HashSet<string> _dirty = new(StringComparer.Ordinal);
    private byte[]? _artwork;
    private bool _removeArtwork;
    private string? _mbRecordingId;
    private string? _mbReleaseId;

    public TagEditorView(IReadOnlyList<Track> tracks)
    {
        _tracks = tracks;
        InitializeComponent();

        var single = tracks.Count == 1 ? tracks[0] : null;
        var batch = tracks.Count > 1;
        if (batch)
        {
            BatchNote.Text = $"Editing {tracks.Count} tracks. Only fields you change are applied; the rest stay untouched. Title, track number and lyrics stay per-track.";
            BatchNote.Visibility = Visibility.Visible;
            TitleBox.IsEnabled = false;
            TrackNumberBox.IsEnabled = false;
            LyricsBox.IsEnabled = false;
        }
        if (single is not null)
        {
            TitleBox.Text = single.Title ?? "";
            ArtistBox.Text = single.Artist ?? "";
            AlbumBox.Text = single.Album ?? "";
            AlbumArtistBox.Text = single.AlbumArtist ?? "";
            GenreBox.Text = single.Genre ?? "";
            ComposerBox.Text = single.Composer ?? "";
            YearBox.Text = single.Year?.ToString() ?? "";
            TrackNumberBox.Text = single.TrackNumber?.ToString() ?? "";
            TrackTotalBox.Text = single.TrackTotal?.ToString() ?? "";
            DiscNumberBox.Text = single.DiscNumber?.ToString() ?? "";
            DiscTotalBox.Text = single.DiscTotal?.ToString() ?? "";
            BpmBox.Text = single.Bpm?.ToString() ?? "";
            CommentBox.Text = single.Comment ?? "";
            _mbRecordingId = single.MusicBrainzRecordingId;
            _mbReleaseId = single.MusicBrainzReleaseId;
            if (!string.IsNullOrEmpty(single.FilePath))
                LyricsBox.Text = App.Services.GetRequiredService<ITagService>().ReadLyrics(single.FilePath) ?? "";
            LoadArtworkPreview(single);
            MbSearchButton.IsEnabled = true;
            MbAutoButton.IsEnabled = true;
        }
        else
        {
            MbSearchButton.IsEnabled = false;
            MbAutoButton.Content = "Auto-match all";
            MbStatus.Text = "Auto-match queries MusicBrainz per track and applies matches scoring 90+.";
            LoadArtworkPreview(tracks[0]);
        }
        if (!batch) MbAutoButton.IsEnabled = single is not null;
        if (batch) MbSearchButton.Visibility = Visibility.Collapsed;

        foreach (var (box, field) in new (TextBox Box, string Field)[]
        {
            (TitleBox, "Title"), (ArtistBox, "Artist"), (AlbumBox, "Album"), (AlbumArtistBox, "AlbumArtist"),
            (GenreBox, "Genre"), (ComposerBox, "Composer"), (YearBox, "Year"), (TrackNumberBox, "TrackNumber"),
            (TrackTotalBox, "TrackTotal"), (DiscNumberBox, "DiscNumber"), (DiscTotalBox, "DiscTotal"),
            (BpmBox, "Bpm"), (CommentBox, "Comment"), (LyricsBox, "Lyrics"),
        })
        {
            var b = box;
            var f = field;
            b.TextChanged += (_, _) => _dirty.Add(f);
        }
    }

    private void LoadArtworkPreview(Track track)
    {
        string? path = null;
        try
        {
            if (track.ArtworkHash is { } h)
                path = App.Services.GetRequiredService<IArtworkCache>().GetPath(h);
            if (path is null && !string.IsNullOrEmpty(track.FilePath))
            {
                var bytes = App.Services.GetRequiredService<ITagService>().ReadArtwork(track.FilePath);
                if (bytes is not null) SetArtworkPreview(bytes);
            }
        }
        catch (Exception) { }
        if (path is not null)
            ArtworkImage.Source = new BitmapImage(new Uri(path));
        else if (ArtworkImage.Source is null)
            ArtworkImage.Source = new BitmapImage(new Uri(System.IO.Path.Combine(AppContext.BaseDirectory, "Assets", "default-artwork.png")));
        ArtworkNote.Text = track.FilePath is null ? "Artwork is written into the file for local tracks." : "";
    }

    private void SetArtworkPreview(byte[] bytes)
    {
        var bmp = new BitmapImage();
        using var stream = new MemoryStream(bytes);
        bmp.SetSource(stream.AsRandomAccessStream());
        ArtworkImage.Source = bmp;
    }

    private async void PickArtwork_Click(object sender, RoutedEventArgs e)
    {
        var picker = new Windows.Storage.Pickers.FileOpenPicker { SuggestedStartLocation = Windows.Storage.Pickers.PickerLocationId.PicturesLibrary };
        picker.FileTypeFilter.Add(".jpg"); picker.FileTypeFilter.Add(".jpeg"); picker.FileTypeFilter.Add(".png"); picker.FileTypeFilter.Add(".webp");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, App.MainWindowHandle);
        var file = await picker.PickSingleFileAsync();
        if (file is null) return;
        _artwork = await File.ReadAllBytesAsync(file.Path);
        _removeArtwork = false;
        SetArtworkPreview(_artwork);
        _dirty.Add("Artwork");
    }

    private void RemoveArtwork_Click(object sender, RoutedEventArgs e)
    {
        _artwork = null;
        _removeArtwork = true;
        _dirty.Add("Artwork");
        ArtworkImage.Source = new BitmapImage(new Uri(System.IO.Path.Combine(AppContext.BaseDirectory, "Assets", "default-artwork.png")));
    }

    /// <summary>Builds the TagEdit from dirty fields. Throws FormatException on invalid numbers.</summary>
    public TagEdit BuildEdit()
    {
        int? Num(TextBox b, string name)
        {
            if (!_dirty.Contains(name)) return null;
            if (string.IsNullOrWhiteSpace(b.Text)) return 0; // clears the field
            if (int.TryParse(b.Text.Trim(), out var v)) return v;
            throw new FormatException($"'{b.Text}' is not a valid number for {b.Header}.");
        }
        string? Str(TextBox b, string name) => _dirty.Contains(name) ? b.Text.Trim() : null;

        return new TagEdit
        {
            Title = Str(TitleBox, "Title"),
            Artist = Str(ArtistBox, "Artist"),
            Album = Str(AlbumBox, "Album"),
            AlbumArtist = Str(AlbumArtistBox, "AlbumArtist"),
            Genre = Str(GenreBox, "Genre"),
            Composer = Str(ComposerBox, "Composer"),
            Year = Num(YearBox, "Year"),
            TrackNumber = Num(TrackNumberBox, "TrackNumber"),
            TrackTotal = Num(TrackTotalBox, "TrackTotal"),
            DiscNumber = Num(DiscNumberBox, "DiscNumber"),
            DiscTotal = Num(DiscTotalBox, "DiscTotal"),
            Bpm = Num(BpmBox, "Bpm"),
            Comment = Str(CommentBox, "Comment"),
            Lyrics = Str(LyricsBox, "Lyrics"),
            Artwork = _dirty.Contains("Artwork") ? _artwork : null,
            RemoveArtwork = _dirty.Contains("Artwork") && _removeArtwork,
            MusicBrainzRecordingId = _dirty.Contains("MB") ? _mbRecordingId : null,
            MusicBrainzReleaseId = _dirty.Contains("MB") ? _mbReleaseId : null,
        };
    }

    private async void MbSearch_Click(object sender, RoutedEventArgs e)
    {
        var track = _tracks[0];
        MbPaws.IsActive = true;
        MbStatus.Text = "Searching MusicBrainz\u2026";
        try
        {
            var mb = App.Services.GetRequiredService<IMusicBrainzService>();
            var matches = await mb.SearchRecordingsAsync(track);
            var items = matches.Select(m => new MbResult(
                $"{m.Title} — {m.Artist}",
                $"{m.ReleaseTitle ?? "?"} {(m.Year is { } y ? $"({y})" : "")} \u00B7 score {m.Score}{(m.TrackNumber is { } n ? $" \u00B7 track {n}" : "")}",
                m)).ToList();
            MbResults.ItemsSource = items;
            MbResults.Visibility = items.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
            MbStatus.Text = items.Count == 0 ? "No matches found." : $"{items.Count} matches — pick one to fill the fields.";
        }
        catch (Exception ex)
        {
            MbStatus.Text = "Lookup failed: " + ex.Message;
        }
        finally { MbPaws.IsActive = false; }
    }

    private void MbResults_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is not MbResult r) return;
        var m = r.Match;
        TitleBox.Text = m.Title; _dirty.Add("Title");
        ArtistBox.Text = m.Artist; _dirty.Add("Artist");
        if (m.ReleaseTitle is not null) { AlbumBox.Text = m.ReleaseTitle; _dirty.Add("Album"); }
        if (m.Year is { } y) { YearBox.Text = y.ToString(); _dirty.Add("Year"); }
        if (m.TrackNumber is { } tn) { TrackNumberBox.Text = tn.ToString(); _dirty.Add("TrackNumber"); }
        if (m.TrackCount is { } tc) { TrackTotalBox.Text = tc.ToString(); _dirty.Add("TrackTotal"); }
        if (m.DiscNumber is { } dn) { DiscNumberBox.Text = dn.ToString(); _dirty.Add("DiscNumber"); }
        if (m.DiscCount is { } dc) { DiscTotalBox.Text = dc.ToString(); _dirty.Add("DiscTotal"); }
        _mbRecordingId = m.RecordingId;
        _mbReleaseId = m.ReleaseId;
        _dirty.Add("MB");
        MbStatus.Text = "Fields filled from MusicBrainz — review and save.";
        MbResults.Visibility = Visibility.Collapsed;
    }

    private async void MbAuto_Click(object sender, RoutedEventArgs e)
    {
        var mb = App.Services.GetRequiredService<IMusicBrainzService>();
        var notifications = App.Services.GetRequiredService<NotificationService>();
        MbPaws.IsActive = true;
        if (_tracks.Count == 1)
        {
            try
            {
                var match = await mb.FindBestMatchAsync(_tracks[0]);
                if (match is null) MbStatus.Text = "No confident match (needs score 90+ and matching length).";
                else
                {
                    await mb.ApplyAsync(_tracks[0], match);
                    await RescanAsync();
                    MbStatus.Text = $"Applied: {match.Title} — {match.Artist}.";
                    notifications.Success("MusicBrainz match applied", match.Title);
                }
            }
            catch (Exception ex) { MbStatus.Text = "Lookup failed: " + ex.Message; }
            finally { MbPaws.IsActive = false; }
        }
        else
        {
            var applied = 0;
            var failed = 0;
            for (var idx = 0; idx < _tracks.Count; idx++)
            {
                var track = _tracks[idx];
                MbStatus.Text = $"Matching {idx + 1}/{_tracks.Count}: {track.DisplayTitle}";
                try
                {
                    var match = await mb.FindBestMatchAsync(track);
                    if (match is not null) { await mb.ApplyAsync(track, match); applied++; }
                }
                catch (Exception) { failed++; }
            }
            MbPaws.IsActive = false;
            await RescanAsync();
            MbStatus.Text = $"Auto-match done: {applied} applied{(failed > 0 ? $", {failed} failed" : "")}.";
            notifications.Success("MusicBrainz auto-match", MbStatus.Text);
        }
    }

    private async Task RescanAsync()
    {
        var paths = _tracks.Where(t => !string.IsNullOrEmpty(t.FilePath)).Select(t => t.FilePath!).ToList();
        if (paths.Count == 0) return;
        var scanner = App.Services.GetRequiredService<MuurMusic.Core.Library.ILibraryScanner>();
        try { await scanner.ScanFilesAsync(paths); } catch (Exception) { }
    }
}
