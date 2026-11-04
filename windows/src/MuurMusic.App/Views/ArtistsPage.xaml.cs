using Microsoft.UI.Xaml.Controls;
using MuurMusic.App.ViewModels;

namespace MuurMusic.App.Views;

public partial class ArtistsPage : Page
{
    protected virtual bool AlbumArtists => false;

    protected override async void OnNavigatedTo(Microsoft.UI.Xaml.Navigation.NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        Grid.Initialize(AlbumArtists);
        await Grid.LoadIfNeededAsync();
    }

    private void FilterBox_TextChanged(object sender, TextChangedEventArgs e) => Grid.ViewModel.Filter = FilterBox.Text;
}
