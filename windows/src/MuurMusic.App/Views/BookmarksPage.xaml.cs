using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using MuurMusic.App.Services;
using MuurMusic.App.ViewModels;
using MuurMusic.Core.Models;

namespace MuurMusic.App.Views;

public sealed partial class BookmarksPage : Page
{
    public BookmarksPage()
    {
        InitializeComponent();
        ViewModel = App.Services.GetRequiredService<BookmarksViewModel>();
    }

    public BookmarksViewModel ViewModel { get; }

    protected override async void OnNavigatedTo(Microsoft.UI.Xaml.Navigation.NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        await ViewModel.LoadAsync();
    }

    private async void List_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is Bookmark bookmark) await ViewModel.GoToCommand.ExecuteAsync(bookmark);
    }

    private void List_RightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        if ((e.OriginalSource as FrameworkElement)?.DataContext is not Bookmark bookmark) return;
        var menu = new MenuFlyout();
        var go = new MenuFlyoutItem { Text = "Jump to position", Icon = new FontIcon { Glyph = "\uE768" } };
        go.Click += async (_, _) => await ViewModel.GoToCommand.ExecuteAsync(bookmark);
        var delete = new MenuFlyoutItem { Text = "Delete bookmark", Icon = new FontIcon { Glyph = "\uE74D" } };
        delete.Click += async (_, _) => await ViewModel.DeleteCommand.ExecuteAsync(bookmark);
        menu.Items.Add(go);
        menu.Items.Add(delete);
        menu.ShowAt((FrameworkElement)sender, e.GetPosition((FrameworkElement)sender));
    }
}
