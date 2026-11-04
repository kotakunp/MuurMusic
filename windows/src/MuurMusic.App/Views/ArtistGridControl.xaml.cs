using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using MuurMusic.App.Services;
using MuurMusic.App.ViewModels;

namespace MuurMusic.App.Views;

/// <summary>Artist artwork grid, shared by Artists and Album Artists pages.</summary>
public sealed partial class ArtistGridControl : UserControl
{
    public ArtistGridControl() => InitializeComponent();

    public ArtistsViewModel ViewModel { get; private set; } = null!;

    public void Initialize(bool albumArtists)
    {
        ViewModel = App.Services.GetRequiredService<ArtistsViewModel>();
        ViewModel.AlbumArtists = albumArtists;
    }

    public async Task LoadIfNeededAsync()
    {
        if (ViewModel.Artists.Count == 0) await ViewModel.LoadAsync();
    }

    private void Grid_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is ArtistCardViewModel card)
            App.Services.GetRequiredService<NavigationService>().Navigate("artist", new ArtistNavigation(card.Name, ViewModel.AlbumArtists));
    }
}
