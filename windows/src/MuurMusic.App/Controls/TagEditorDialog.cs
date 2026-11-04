using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml.Controls;
using MuurMusic.App.Services;
using MuurMusic.Core.Models;
using MuurMusic.Core.Tags;

namespace MuurMusic.App.Controls;

/// <summary>Tag editor dialog: single or batch, with artwork and MusicBrainz lookup.</summary>
public static class TagEditorDialog
{
    public static async Task ShowForAsync(IReadOnlyList<Track> tracks)
    {
        if (tracks.Count == 0 || App.CurrentWindow is null) return;
        var notifications = App.Services.GetRequiredService<NotificationService>();
        var tags = App.Services.GetRequiredService<ITagService>();

        var writable = tracks.Where(t => !string.IsNullOrEmpty(t.FilePath) && tags.CanHandle(t.FilePath!)).ToList();
        if (writable.Count == 0)
        {
            notifications.Warning("Tag editing unavailable", "Tag editing works on local files (FLAC, MP3, M4A, Opus\u2026). Remote tracks are not writable.");
            return;
        }

        var view = new TagEditorView(writable);
        var dialog = new ContentDialog
        {
            Title = writable.Count == 1 ? $"Edit tags — {writable[0].DisplayTitle}" : $"Edit tags — {writable.Count} tracks",
            Content = view,
            PrimaryButtonText = "Save",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = App.CurrentWindow.Content.XamlRoot,
        };
        if (writable.Count < tracks.Count)
            notifications.Info("Some tracks skipped", $"{tracks.Count - writable.Count} remote or unsupported file(s) can't be tag-edited.");

        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;

        TagEdit edit;
        try
        {
            edit = view.BuildEdit();
        }
        catch (FormatException ex)
        {
            notifications.Error("Invalid value", ex.Message);
            return;
        }
        if (edit.IsEmpty)
        {
            notifications.Info("Nothing to save", "No fields were changed.");
            return;
        }

        var paths = new List<string>();
        var failed = 0;
        foreach (var track in writable)
        {
            try
            {
                await tags.WriteAsync(track.FilePath!, edit);
                paths.Add(track.FilePath!);
            }
            catch (Exception ex)
            {
                failed++;
                notifications.Error("Could not write tags", $"{track.DisplayTitle}: {ex.Message}");
            }
        }
        if (paths.Count > 0)
        {
            var scanner = App.Services.GetRequiredService<MuurMusic.Core.Library.ILibraryScanner>();
            await scanner.ScanFilesAsync(paths);
            notifications.Success("Tags saved", failed == 0 ? $"{paths.Count} file{(paths.Count == 1 ? "" : "s")} updated." : $"{paths.Count} updated, {failed} failed.");
        }
    }
}
