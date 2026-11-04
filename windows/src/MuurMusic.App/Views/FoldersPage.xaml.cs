using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using MuurMusic.App.Services;
using MuurMusic.App.ViewModels;
using MuurMusic.Core.Models;

namespace MuurMusic.App.Views;

public sealed partial class FoldersPage : Page
{
    public FoldersPage()
    {
        InitializeComponent();
        ViewModel = App.Services.GetRequiredService<FoldersViewModel>();
        ViewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(FoldersViewModel.Folders) or nameof(FoldersViewModel.Tracks))
                UpdateBindings();
            if (e.PropertyName is nameof(FoldersViewModel.CurrentPath))
                TrackRows.ItemsSource = ViewModel.Tracks.ToList();
        };
    }

    public FoldersViewModel ViewModel { get; }

    protected override async void OnNavigatedTo(Microsoft.UI.Xaml.Navigation.NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        await ViewModel.LoadRootsAsync();
        TrackRows.ItemsSource = ViewModel.Tracks.ToList();
        UpdateBindings();
    }

    private void UpdateBindings() => ViewModel.NotifyFoldersChanged();

    private async void Folder_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is FolderCardItem folder) await ViewModel.OpenFolderAsync(folder.Path);
        TrackRows.ItemsSource = ViewModel.Tracks.ToList();
    }

    private async void Up_Click(object sender, RoutedEventArgs e)
    {
        await ViewModel.GoUpCommand.ExecuteAsync(null);
        TrackRows.ItemsSource = ViewModel.Tracks.ToList();
    }

    private async void TrackRows_PlayRequested(object? sender, Track track) =>
        await ViewModel.PlayTracksAsync(ViewModel.Tracks.ToList(), track);

    private async void PlayFolder_Click(object sender, RoutedEventArgs e) =>
        await ViewModel.PlayFolderCommand.ExecuteAsync(null);

    private async void AddFolder_Click(object sender, RoutedEventArgs e)
    {
        var folder = await App.Services.GetRequiredService<DialogService>().PickFolderAsync();
        if (folder is null) return;
        await App.Services.GetRequiredService<MuurMusic.Core.Library.ILibraryScanner>().AddFolderAsync(folder);
        await ViewModel.LoadRootsAsync();
    }
}
