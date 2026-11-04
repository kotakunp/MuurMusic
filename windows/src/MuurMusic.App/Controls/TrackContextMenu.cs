using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml.Controls;
using MuurMusic.App.Services;
using MuurMusic.Audio.Playback;
using MuurMusic.Core.Data;
using MuurMusic.Core.Downloads;
using MuurMusic.Core.Models;

namespace MuurMusic.App.Controls;

/// <summary>Shared context menu for tracks everywhere (songs, albums, playlists, folders, search results).</summary>
public static class TrackContextMenu
{
    public static async Task<MenuFlyout> BuildAsync(IReadOnlyList<Track> selection, IReadOnlyList<Track> playContext)
    {
        var notifications = App.Services.GetRequiredService<NotificationService>();
        var playback = App.Services.GetRequiredService<IPlaybackService>();
        var tracks = App.Services.GetRequiredService<ITrackRepository>();
        var playlists = App.Services.GetRequiredService<IPlaylistRepository>();
        var downloads = App.Services.GetRequiredService<IDownloadManager>();

        var menu = new MenuFlyout();
        var single = selection.Count == 1 ? selection[0] : null;
        var multi = selection.Count > 1 ? $" ({selection.Count} tracks)" : "";

        var play = new MenuFlyoutItem { Text = "Play", Icon = new FontIcon { Glyph = "\uE768" } };
        play.Click += async (_, _) =>
        {
            if (playContext.Count == 0) return;
            var index = single is null ? 0 : Math.Max(0, IndexOf(playContext, single));
            await playback.PlayAsync(playContext, index);
        };
        menu.Items.Add(play);

        var playNext = new MenuFlyoutItem { Text = "Play next" + multi, Icon = new FontIcon { Glyph = "\uE0E7" } };
        playNext.Click += (_, _) =>
        {
            playback.EnqueueNext(selection);
            notifications.Success("Up next", CountLabel(selection));
        };
        menu.Items.Add(playNext);

        var playLater = new MenuFlyoutItem { Text = "Play later" + multi, Icon = new FontIcon { Glyph = "\uE8FD" } };
        playLater.Click += (_, _) =>
        {
            playback.EnqueueLast(selection);
            notifications.Success("Queued", CountLabel(selection));
        };
        menu.Items.Add(playLater);

        var addTo = new MenuFlyoutSubItem { Text = "Add to playlist" + multi, Icon = new FontIcon { Glyph = "\uE8F1" } };
        var newPl = new MenuFlyoutItem { Text = "New playlist\u2026", Icon = new FontIcon { Glyph = "\uE710" } };
        newPl.Click += async (_, _) =>
        {
            var name = await App.Services.GetRequiredService<DialogService>().PromptAsync("New playlist", "Playlist name");
            if (name is null) return;
            var pl = await playlists.CreateAsync(name);
            await playlists.AddTracksAsync(pl.Id, selection);
            notifications.Success("Playlist created", $"\u201C{name}\u201D with {selection.Count} track{(selection.Count == 1 ? "" : "s")}.");
        };
        addTo.Items.Add(newPl);
        foreach (var pl in (await playlists.GetAllAsync()).Where(p => !p.IsSmart))
        {
            var item = new MenuFlyoutItem { Text = pl.Name };
            var captured = pl;
            item.Click += async (_, _) =>
            {
                await playlists.AddTracksAsync(captured.Id, selection);
                notifications.Success("Added to playlist", $"{CountLabel(selection)} \u2192 {captured.Name}");
            };
            addTo.Items.Add(item);
        }
        menu.Items.Add(addTo);

        if (single is { Id: > 0 })
        {
            var fav = new MenuFlyoutItem { Text = single.Favorite ? "Remove from favorites" : "Favorite", Icon = new FontIcon { Glyph = "\uE734" } };
            fav.Click += async (_, _) => await tracks.SetFavoriteAsync(single.Id, !single.Favorite);
            menu.Items.Add(fav);
        }

        var rate = new MenuFlyoutSubItem { Text = "Rating", Icon = new FontIcon { Glyph = "\uE735" } };
        for (var stars = 0; stars <= 5; stars++)
        {
            var item = new MenuFlyoutItem { Text = stars == 0 ? "No rating" : new string('\u2605', stars) };
            var n = stars;
            item.Click += async (_, _) =>
            {
                foreach (var t in selection.Where(t => t.Id > 0))
                    await tracks.SetRatingAsync(t.Id, n);
                notifications.Success("Rating set", selection.Count == 1 ? selection[0].DisplayTitle : $"{selection.Count} tracks \u2192 {n}\u2605");
            };
            rate.Items.Add(item);
        }
        menu.Items.Add(rate);

        menu.Items.Add(new MenuFlyoutSeparator());

        var tags = new MenuFlyoutItem { Text = "Edit tags\u2026" + multi, Icon = new FontIcon { Glyph = "\uE70F" } };
        tags.Click += async (_, _) => await TagEditorDialog.ShowForAsync(selection);
        menu.Items.Add(tags);

        var offline = new MenuFlyoutItem { Text = "Download for offline" + multi, Icon = new FontIcon { Glyph = "\uE896" } };
        offline.Click += async (_, _) =>
        {
            try
            {
                var items = await downloads.MakeAvailableOfflineAsync(selection);
                notifications.Success("Downloading for offline", $"{items.Count} item{(items.Count == 1 ? "" : "s")} queued.");
            }
            catch (Exception ex) { notifications.Error("Download failed", ex.Message); }
        };
        menu.Items.Add(offline);

        if (single is not null)
        {
            var reveal = new MenuFlyoutItem { Text = "Reveal in file manager", Icon = new FontIcon { Glyph = "\uEC50" } };
            reveal.Click += (_, _) =>
            {
                if (single.FilePath is { } path && System.IO.File.Exists(path))
                    System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = true });
                else notifications.Warning("Not a local file", "This track lives on a remote source.");
            };
            menu.Items.Add(reveal);

            var bookmark = new MenuFlyoutItem { Text = "Bookmark position", Icon = new FontIcon { Glyph = "\uE8A4" } };
            bookmark.Click += async (_, _) =>
            {
                var current = playback.CurrentTrack;
                if (current is null || current.Key != single.Key)
                {
                    await playback.PlayAsync(new[] { single });
                    notifications.Info("Playing first", "Bookmark from the player once it reaches the right spot.");
                    return;
                }
                var b = await playback.AddBookmarkAsync();
                notifications.Success("Bookmark saved", b is null ? null : $"{single.DisplayTitle} at {b.Position:m\\:ss}");
            };
            menu.Items.Add(bookmark);
        }
        return menu;
    }

    private static string CountLabel(IReadOnlyList<Track> selection) =>
        selection.Count == 1 ? selection[0].DisplayTitle : $"{selection.Count} tracks";

    private static int IndexOf(IReadOnlyList<Track> list, Track track)
    {
        for (var i = 0; i < list.Count; i++)
            if (list[i].Key == track.Key) return i;
        return -1;
    }
}
