using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using MuurMusic.App.ViewModels;
using MuurMusic.Audio.Casting;

namespace MuurMusic.App.Controls;

public sealed partial class CastFlyoutContent : UserControl
{
    public CastFlyoutContent()
    {
        InitializeComponent();
        ViewModel = App.Services.GetRequiredService<PlayerBarViewModel>();
        Loaded += (_, _) => Refresh();
        ViewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(PlayerBarViewModel.IsCasting) or nameof(PlayerBarViewModel.CastDeviceName)) Refresh();
            if (e.PropertyName == nameof(PlayerBarViewModel.IsDiscoveringCast)) CastPaws.IsActive = ViewModel.IsDiscoveringCast;
        };
        DeviceList.ItemsSource = ViewModel.CastDevices;
    }

    public PlayerBarViewModel ViewModel { get; }

    private void Refresh()
    {
        ActiveCastBanner.Visibility = ViewModel.IsCasting ? Visibility.Visible : Visibility.Collapsed;
        ActiveCastName.Text = ViewModel.CastDeviceName ?? "";
        CastPaws.IsActive = ViewModel.IsDiscoveringCast;
        NoDevicesText.Visibility = ViewModel.CastDevices.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private async void Discover_Click(object sender, RoutedEventArgs e)
    {
        NoDevicesText.Visibility = Visibility.Collapsed;
        await ViewModel.DiscoverCastDevicesCommand.ExecuteAsync(null);
        Refresh();
    }

    private async void DeviceList_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is CastDeviceInfo device)
            await ViewModel.ConnectCastCommand.ExecuteAsync(device);
    }

    private async void DisconnectCast_Click(object sender, RoutedEventArgs e) =>
        await ViewModel.DisconnectCastCommand.ExecuteAsync(null);
}
