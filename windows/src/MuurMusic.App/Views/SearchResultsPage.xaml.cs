using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using MuurMusic.App.Services;
using MuurMusic.App.ViewModels;
using MuurMusic.Core.Models;

namespace MuurMusic.App.Views;

public sealed partial class SearchResultsPage : Page
{
    public SearchResultsPage()
    {
        InitializeComponent();
        ViewModel = App.Services.GetRequiredService<SearchResultsViewModel>();
    }

    public SearchResultsViewModel ViewModel { get; }

    protected override async void OnNavigatedTo(Microsoft.UI.Xaml.Navigation.NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        await ViewModel.SearchAsync(e.Parameter as string ?? "");
        TrackRows.ItemsSource = ViewModel.Tracks.ToList();
    }

    private async void TrackRows_PlayRequested(object? sender, Track track) => await ViewModel.PlayAsync(track);
    private async void PlayAll_Click(object sender, RoutedEventArgs e) => await ViewModel.PlayAllCommand.ExecuteAsync(null);

    private void Album_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is AlbumCardViewModel card)
            App.Services.GetRequiredService<NavigationService>().Navigate("album", card.Album.Key);
    }

    private void Artist_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is ArtistCardViewModel card)
            App.Services.GetRequiredService<NavigationService>().Navigate("artist", new ArtistNavigation(card.Name, false));
    }

    private void Playlist_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is PlaylistCardViewModel card)
            App.Services.GetRequiredService<NavigationService>().Navigate("playlist", card.Id);
    }

    private void Folder_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is FolderCardItem folder)
            App.Services.GetRequiredService<NavigationService>().Navigate("files", folder.Path);
    }
}
