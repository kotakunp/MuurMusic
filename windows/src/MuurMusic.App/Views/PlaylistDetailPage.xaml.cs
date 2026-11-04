using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using MuurMusic.App.Services;
using MuurMusic.App.ViewModels;

namespace MuurMusic.App.Views;

public sealed partial class PlaylistDetailPage : Page
{
    public PlaylistDetailPage()
    {
        InitializeComponent();
        ViewModel = App.Services.GetRequiredService<PlaylistDetailViewModel>();
    }

    public PlaylistDetailViewModel ViewModel { get; }

    protected override async void OnNavigatedTo(Microsoft.UI.Xaml.Navigation.NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        if (e.Parameter is long id) await ViewModel.LoadAsync(id);
    }

    private async void List_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is PlaylistEntryItemViewModel item) await ViewModel.PlayEntryAsync(item);
    }

    private void List_RightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        if ((e.OriginalSource as FrameworkElement)?.DataContext is not PlaylistEntryItemViewModel item) return;
        var menu = new MenuFlyout();
        var play = new MenuFlyoutItem { Text = "Play", Icon = new FontIcon { Glyph = "\uE768" } };
        play.Click += async (_, _) => await ViewModel.PlayEntryAsync(item);
        menu.Items.Add(play);
        if (!ViewModel.IsSmart)
        {
            var remove = new MenuFlyoutItem { Text = "Remove from playlist", Icon = new FontIcon { Glyph = "\uE74D" } };
            remove.Click += async (_, _) => await ViewModel.RemoveAsync(item);
            menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(remove);
        }
        menu.ShowAt(List, e.GetPosition(List));
    }

    private void List_DragItemsStarting(object sender, DragItemsStartingEventArgs e) { }

    private async void List_DragItemsCompleted(ListViewBase sender, DragItemsCompletedEventArgs args)
    {
        // ListView already reordered the bound collection visually; persist the new order.
        // MoveEntryAsync(from, to) uses positions, so persist with a full reorder instead.
        await ViewModel.PersistOrderAsync();
    }

    private async void Play_Click(object sender, RoutedEventArgs e) => await ViewModel.PlayAllCommand.ExecuteAsync(null);

    private void EditSmart_Click(object sender, RoutedEventArgs e)
    {
        if (ViewModel.Playlist is { } playlist)
            App.Services.GetRequiredService<NavigationService>().Navigate("smarteditor", playlist);
    }

    private async void Export_Click(object sender, RoutedEventArgs e) => await ViewModel.ExportCommand.ExecuteAsync(null);
}
