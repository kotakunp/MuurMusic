using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using MuurMusic.App.Services;
using MuurMusic.App.ViewModels;

namespace MuurMusic.App.Views;

public sealed partial class DownloadsPage : Page
{
    public DownloadsPage()
    {
        InitializeComponent();
        ViewModel = App.Services.GetRequiredService<DownloadsViewModel>();
    }

    public DownloadsViewModel ViewModel { get; }

    protected override async void OnNavigatedTo(Microsoft.UI.Xaml.Navigation.NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        await ViewModel.LoadAsync();
    }

    private void PauseAll_Click(object sender, RoutedEventArgs e) => ViewModel.PauseAllCommand.Execute(null);
    private void ResumeAll_Click(object sender, RoutedEventArgs e) => ViewModel.ResumeAllCommand.Execute(null);
    private async void ClearFinished_Click(object sender, RoutedEventArgs e) => await ViewModel.ClearFinishedCommand.ExecuteAsync(null);
    private async void ApplyCacheLimit_Click(object sender, RoutedEventArgs e) => await ViewModel.ApplyCacheLimitCommand.ExecuteAsync(null);
    private async void ClearCache_Click(object sender, RoutedEventArgs e) => await ViewModel.ClearCacheCommand.ExecuteAsync(null);
    private void OpenFolder_Click(object sender, RoutedEventArgs e) => ViewModel.OpenDownloadFolderCommand.Execute(null);
    private async void ChangeFolder_Click(object sender, RoutedEventArgs e) => await ViewModel.ChangeDownloadFolderCommand.ExecuteAsync(null);
}
