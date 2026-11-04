using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using MuurMusic.App.ViewModels;
using MuurMusic.Audio.Output;

namespace MuurMusic.App.Controls;

public sealed partial class VolumeFlyoutContent : UserControl
{
    public VolumeFlyoutContent()
    {
        InitializeComponent();
        ViewModel = App.Services.GetRequiredService<PlayerBarViewModel>();
        Loaded += (_, _) => DeviceList.ItemsSource = ViewModel.OutputDevices;
        ViewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(PlayerBarViewModel.OutputDevices)) DeviceList.ItemsSource = ViewModel.OutputDevices;
        };
    }

    public PlayerBarViewModel ViewModel { get; }

    private void Mute_Click(object sender, RoutedEventArgs e) => ViewModel.IsMuted = !ViewModel.IsMuted;

    private async void DeviceList_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is OutputDeviceInfo device)
        {
            await ViewModel.SelectOutputDeviceCommand.ExecuteAsync(device);
            DeviceList.ItemsSource = null;
            DeviceList.ItemsSource = ViewModel.OutputDevices;
        }
    }
}
