using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using MuurMusic.App.Services;
using MuurMusic.App.ViewModels;
using MuurMusic.Core.Models;

namespace MuurMusic.App.Views;

public sealed partial class ArtistDetailPage : Page
{
    public ArtistDetailPage()
    {
        InitializeComponent();
        ViewModel = App.Services.GetRequiredService<ArtistDetailViewModel>();
    }

    public ArtistDetailViewModel ViewModel { get; }

    protected override async void OnNavigatedTo(Microsoft.UI.Xaml.Navigation.NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        if (e.Parameter is ArtistNavigation nav)
        {
            await ViewModel.LoadAsync(nav);
            TrackRows.ItemsSource = ViewModel.Tracks.ToList();
        }
    }

    private void Album_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is AlbumCardViewModel card)
            App.Services.GetRequiredService<NavigationService>().Navigate("album", card.Album.Key);
    }

    private async void TrackRows_PlayRequested(object? sender, Track track) => await ViewModel.PlayAsync(track);
    private async void Play_Click(object sender, RoutedEventArgs e) => await ViewModel.PlayAsync(null);
    private async void Shuffle_Click(object sender, RoutedEventArgs e) => await ViewModel.ShufflePlayCommand.ExecuteAsync(null);
}
