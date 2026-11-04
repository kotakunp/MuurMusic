using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml.Controls;
using MuurMusic.App.Services;
using MuurMusic.App.ViewModels;
using MuurMusic.Core.Data;

namespace MuurMusic.App.Views;

/// <summary>Genre/composer name list, shared by the two pages.</summary>
public sealed partial class NameCountListControl : UserControl
{
    public NameCountListControl() => InitializeComponent();

    public GenresViewModel ViewModel { get; private set; } = null!;

    public async Task InitializeAsync(bool composers)
    {
        ViewModel = App.Services.GetRequiredService<GenresViewModel>();
        ViewModel.Composers = composers;
        Bindings.Update();
        await ViewModel.LoadAsync();
    }

    private void List_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is not NameCountItem item) return;
        var query = ViewModel.Composers
            ? new TrackQuery { Composer = item.Name }
            : new TrackQuery { Genre = item.Name };
        App.Services.GetRequiredService<NavigationService>().Navigate("tracklist", new TrackListNavigation(item.Name, query));
    }
}
