using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using MuurMusic.App.ViewModels;

namespace MuurMusic.App.Views;

public sealed partial class SettingsPage : Page
{
    private int _spinAngle;

    public SettingsPage()
    {
        InitializeComponent();
        ViewModel = App.Services.GetRequiredService<SettingsViewModel>();
    }

    public SettingsViewModel ViewModel { get; }

    protected override async void OnNavigatedTo(Microsoft.UI.Xaml.Navigation.NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        ViewModel.SetVersion();
        await ViewModel.LoadLibraryStatsAsync();
        AboutLogo.Tapped += AboutLogo_Tapped;
    }

    protected override void OnNavigatedFrom(Microsoft.UI.Xaml.Navigation.NavigationEventArgs e)
    {
        AboutLogo.Tapped -= AboutLogo_Tapped;
        base.OnNavigatedFrom(e);
    }

    private void AboutLogo_Tapped(object sender, TappedRoutedEventArgs e)
    {
        ViewModel.AboutClickedCommand.Execute(null);
        _spinAngle += 72;
        if (AboutLogo.RenderTransform is RotateTransform rotate) rotate.Angle = _spinAngle % 360;
        Bindings.Update();
    }

    private void RemoveFolder_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string folder }) ViewModel.RemoveFolderCommand.Execute(folder);
    }
}
