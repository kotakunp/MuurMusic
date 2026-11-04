using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using MuurMusic.App.Services;
using MuurMusic.App.ViewModels;

namespace MuurMusic.App.Views;

public sealed partial class PlaylistsPage : Page
{
    public PlaylistsPage()
    {
        InitializeComponent();
        ViewModel = App.Services.GetRequiredService<PlaylistsViewModel>();
    }

    public PlaylistsViewModel ViewModel { get; }

    protected override async void OnNavigatedTo(Microsoft.UI.Xaml.Navigation.NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        await ViewModel.LoadAsync();
    }

    private void Grid_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is PlaylistCardViewModel card)
            App.Services.GetRequiredService<NavigationService>().Navigate("playlist", card.Id);
    }

    private void Grid_RightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        if ((e.OriginalSource as FrameworkElement)?.DataContext is not PlaylistCardViewModel card) return;
        var menu = new MenuFlyout();
        var open = new MenuFlyoutItem { Text = "Open", Icon = new FontIcon { Glyph = "\uE8A7" } };
        open.Click += (_, _) => App.Services.GetRequiredService<NavigationService>().Navigate("playlist", card.Id);
        var rename = new MenuFlyoutItem { Text = "Rename", Icon = new FontIcon { Glyph = "\uE70F" } };
        rename.Click += async (_, _) => await ViewModel.RenameAsync(card);
        var duplicate = new MenuFlyoutItem { Text = "Duplicate", Icon = new FontIcon { Glyph = "\uE8C8" } };
        duplicate.Click += async (_, _) => await ViewModel.DuplicateAsync(card);
        var delete = new MenuFlyoutItem { Text = "Delete", Icon = new FontIcon { Glyph = "\uE74D" } };
        delete.Click += async (_, _) => await ViewModel.DeleteAsync(card);
        menu.Items.Add(open);
        menu.Items.Add(rename);
        menu.Items.Add(duplicate);
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(delete);
        menu.ShowAt(Grid, e.GetPosition(Grid));
    }

    private async void NewPlaylist_Click(object sender, RoutedEventArgs e)
    {
        if (await ViewModel.CreateAsync() is { } id)
            App.Services.GetRequiredService<NavigationService>().Navigate("playlist", id);
    }

    private async void NewSmart_Click(object sender, RoutedEventArgs e)
    {
        var name = await App.Services.GetRequiredService<DialogService>().PromptAsync("New smart playlist", "Name:", "My smart playlist");
        if (string.IsNullOrWhiteSpace(name)) return;
        App.Services.GetRequiredService<NavigationService>().Navigate("smarteditor", name.Trim());
    }

    private async void Import_Click(object sender, RoutedEventArgs e) => await ViewModel.ImportAsync();
}
