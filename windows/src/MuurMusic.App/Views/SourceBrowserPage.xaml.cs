using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using MuurMusic.App.Services;
using MuurMusic.App.ViewModels;

namespace MuurMusic.App.Views;

public sealed partial class SourceBrowserPage : Page
{
    public SourceBrowserPage()
    {
        InitializeComponent();
        ViewModel = App.Services.GetRequiredService<SourceBrowserViewModel>();
    }

    public SourceBrowserViewModel ViewModel { get; }

    protected override async void OnNavigatedTo(Microsoft.UI.Xaml.Navigation.NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        if (e.Parameter is Guid sourceId) await ViewModel.LoadAsync(sourceId);
    }

    private async void List_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is BrowserItemViewModel item) await ViewModel.OpenAsync(item);
    }

    private void List_RightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        if ((e.OriginalSource as FrameworkElement)?.DataContext is not BrowserItemViewModel item) return;
        var menu = new MenuFlyout();
        if (item.IsPlayable)
        {
            var play = new MenuFlyoutItem { Text = "Play", Icon = new FontIcon { Glyph = "\uE768" } };
            play.Click += async (_, _) => await ViewModel.PlayAsync(item);
            var next = new MenuFlyoutItem { Text = "Play next", Icon = new FontIcon { Glyph = "\uE0E7" } };
            next.Click += async (_, _) => await ViewModel.EnqueueAsync(item, next: true);
            var later = new MenuFlyoutItem { Text = "Play later", Icon = new FontIcon { Glyph = "\uE8FD" } };
            later.Click += async (_, _) => await ViewModel.EnqueueAsync(item, next: false);
            menu.Items.Add(play);
            menu.Items.Add(next);
            menu.Items.Add(later);
            menu.Items.Add(new MenuFlyoutSeparator());
        }
        var download = new MenuFlyoutItem { Text = item.IsFolder ? "Download folder" : "Download", Icon = new FontIcon { Glyph = "\uE896" } };
        download.Click += async (_, _) => await ViewModel.DownloadAsync(item);
        menu.Items.Add(download);
        menu.ShowAt(List, e.GetPosition(List));
    }

    private async void Up_Click(object sender, RoutedEventArgs e) => await ViewModel.GoUpCommand.ExecuteAsync(null);
    private async void Refresh_Click(object sender, RoutedEventArgs e) => await ViewModel.RefreshCommand.ExecuteAsync(null);
    private async void PlayAll_Click(object sender, RoutedEventArgs e) => await ViewModel.PlayAllCommand.ExecuteAsync(null);
}
