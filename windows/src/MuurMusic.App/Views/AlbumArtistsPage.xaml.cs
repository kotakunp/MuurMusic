using Microsoft.UI.Xaml.Controls;
using MuurMusic.App.ViewModels;

namespace MuurMusic.App.Views;

public partial class AlbumArtistsPage : Page
{
    protected override void OnNavigatedTo(Microsoft.UI.Xaml.Navigation.NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        Grid.Initialize(albumArtists: true);
        _ = Grid.LoadIfNeededAsync();
    }

    private void FilterBox_TextChanged(object sender, TextChangedEventArgs e) => Grid.ViewModel.Filter = FilterBox.Text;
}
