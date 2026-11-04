using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using MuurMusic.App.Services;
using MuurMusic.App.ViewModels;

namespace MuurMusic.App.Views;

public sealed partial class DspChainPage : Page
{
    public DspChainPage()
    {
        InitializeComponent();
        ViewModel = App.Services.GetRequiredService<DspChainViewModel>();
    }

    public DspChainViewModel ViewModel { get; }

    protected override async void OnNavigatedTo(Microsoft.UI.Xaml.Navigation.NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        await ViewModel.LoadSavedChainsAsync();
    }

    private void AddBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (AddBox.SelectedItem is DspNodeTypeItem item)
        {
            ViewModel.AddNodeCommand.Execute(item.Type);
            AddBox.SelectedIndex = -1;
        }
    }

    private void Clear_Click(object sender, RoutedEventArgs e) => ViewModel.ClearCommand.Execute(null);
    private async void LoadSaved_Click(object sender, RoutedEventArgs e) => await ViewModel.LoadSavedChainCommand.ExecuteAsync(null);
    private async void SaveAs_Click(object sender, RoutedEventArgs e) => await ViewModel.SaveChainAsCommand.ExecuteAsync(null);
    private async void DeleteSaved_Click(object sender, RoutedEventArgs e) => await ViewModel.DeleteSavedChainCommand.ExecuteAsync(null);
    private async void Import_Click(object sender, RoutedEventArgs e) => await ViewModel.ImportChainCommand.ExecuteAsync(null);
    private async void Export_Click(object sender, RoutedEventArgs e) => await ViewModel.ExportChainCommand.ExecuteAsync(null);
}
