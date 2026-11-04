using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using MuurMusic.App.Services;
using MuurMusic.App.ViewModels;

namespace MuurMusic.App.Views;

public sealed partial class EqPage : Page
{
    public EqPage()
    {
        InitializeComponent();
        ViewModel = App.Services.GetRequiredService<EqViewModel>();
    }

    public EqViewModel ViewModel { get; }

    protected override async void OnNavigatedTo(Microsoft.UI.Xaml.Navigation.NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        if (ViewModel.PresetNames.Count == 0) await ViewModel.LoadAsync();
        ViewModel.StartMeters();
    }

    protected override void OnNavigatedFrom(Microsoft.UI.Xaml.Navigation.NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        ViewModel.StopMeters();
    }

    private async void Save_Click(object sender, RoutedEventArgs e) => await ViewModel.SavePresetCommand.ExecuteAsync(null);
    private async void Rename_Click(object sender, RoutedEventArgs e) => await ViewModel.RenamePresetCommand.ExecuteAsync(null);
    private async void Delete_Click(object sender, RoutedEventArgs e) => await ViewModel.DeletePresetCommand.ExecuteAsync(null);
    private async void Import_Click(object sender, RoutedEventArgs e) => await ViewModel.ImportPresetsCommand.ExecuteAsync(null);
    private async void Export_Click(object sender, RoutedEventArgs e) => await ViewModel.ExportPresetsCommand.ExecuteAsync(null);
    private void Reset_Click(object sender, RoutedEventArgs e) => ViewModel.ResetCommand.Execute(null);
}
