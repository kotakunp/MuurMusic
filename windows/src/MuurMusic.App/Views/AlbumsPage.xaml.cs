using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using MuurMusic.App.Services;
using MuurMusic.App.ViewModels;

namespace MuurMusic.App.Views;

public sealed partial class AlbumsPage : Page
{
    public AlbumsPage()
    {
        InitializeComponent();
        ViewModel = App.Services.GetRequiredService<AlbumsViewModel>();
    }

    public AlbumsViewModel ViewModel { get; }

    protected override async void OnNavigatedTo(Microsoft.UI.Xaml.Navigation.NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        if (ViewModel.Albums.Count == 0) await ViewModel.LoadAsync();
    }

    private async void SortBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (SortBox.SelectedItem is ComboBoxItem { Tag: string tag })
            await ViewModel.SortByCommand.ExecuteAsync(tag);
    }

    private void FilterBox_TextChanged(object sender, TextChangedEventArgs e) => ViewModel.Filter = FilterBox.Text;

    private void AlbumGrid_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is AlbumCardViewModel card)
            App.Services.GetRequiredService<NavigationService>().Navigate("album", card.Album.Key);
    }

    private async void AlbumGrid_RightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        if ((e.OriginalSource as FrameworkElement)?.DataContext is not AlbumCardViewModel card) return;
        var menu = new MenuFlyout();
        var play = new MenuFlyoutItem { Text = "Play", Icon = new FontIcon { Glyph = "\uE768" } };
        play.Click += async (_, _) => await ViewModel.PlayAlbumAsync(card);
        var shuffle = new MenuFlyoutItem { Text = "Shuffle play", Icon = new FontIcon { Glyph = "\uE8B1" } };
        shuffle.Click += async (_, _) => await ViewModel.PlayAlbumAsync(card, shuffle: true);
        var next = new MenuFlyoutItem { Text = "Play next", Icon = new FontIcon { Glyph = "\uE0E7" } };
        next.Click += async (_, _) => await ViewModel.EnqueueAlbumAsync(card, next: true);
        var later = new MenuFlyoutItem { Text = "Play later", Icon = new FontIcon { Glyph = "\uE8FD" } };
        later.Click += async (_, _) => await ViewModel.EnqueueAlbumAsync(card, next: false);
        var download = new MenuFlyoutItem { Text = "Download for offline", Icon = new FontIcon { Glyph = "\uE896" } };
        download.Click += async (_, _) =>
        {
            var tracks = await App.Services.GetRequiredService<MuurMusic.Core.Data.ITrackRepository>().GetAlbumTracksAsync(card.Album.Key);
            await App.Services.GetRequiredService<MuurMusic.Core.Downloads.IDownloadManager>().MakeAvailableOfflineAsync(tracks);
            App.Services.GetRequiredService<NotificationService>().Success("Downloading", $"{card.Name} queued for offline.");
        };
        menu.Items.Add(play);
        menu.Items.Add(shuffle);
        menu.Items.Add(next);
        menu.Items.Add(later);
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(download);
        menu.ShowAt(AlbumGrid, e.GetPosition(AlbumGrid));
    }

    private async void Rescan_Click(object sender, RoutedEventArgs e) =>
        await App.Services.GetRequiredService<MuurMusic.Core.Library.ILibraryScanner>().ScanAsync();
}
