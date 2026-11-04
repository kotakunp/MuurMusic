using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using MuurMusic.App.Controls;
using MuurMusic.App.Services;
using MuurMusic.App.ViewModels;
using MuurMusic.Core.Data;
using MuurMusic.Core.Models;

namespace MuurMusic.App.Views;

public sealed partial class SongsPage : Page
{
    private bool _loadedOnce;

    public SongsPage()
    {
        InitializeComponent();
        ViewModel = App.Services.GetRequiredService<SongsViewModel>();
        ViewModel.PropertyChanged += OnViewModelPropertyChanged;
        UpdateStates();
    }

    public SongsViewModel ViewModel { get; }

    protected override async void OnNavigatedTo(Microsoft.UI.Xaml.Navigation.NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        if (!_loadedOnce || ViewModel.Tracks.Count == 0)
        {
            _loadedOnce = true;
            await ViewModel.LoadAsync();
        }
        UpdateStates();
    }

    private void OnViewModelPropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(SongsViewModel.IsLoading) or nameof(SongsViewModel.IsEmpty) or nameof(SongsViewModel.IsScanning))
            UpdateStates();
    }

    private void UpdateStates()
    {
        EmptyState.Visibility = ViewModel.IsEmpty && !ViewModel.IsLoading ? Visibility.Visible : Visibility.Collapsed;
        ScanBar.Visibility = ViewModel.IsScanning ? Visibility.Visible : Visibility.Collapsed;
        RescanButton.Visibility = ViewModel.IsScanning ? Visibility.Collapsed : Visibility.Visible;
        CancelScanButton.Visibility = ViewModel.IsScanning ? Visibility.Visible : Visibility.Collapsed;
    }

    private List<Track> Selection() => TrackList.SelectedItems.Cast<Track>().ToList();

    private async void TrackList_DoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        if ((e.OriginalSource as FrameworkElement)?.DataContext is Track track)
            await ViewModel.PlayCommand.ExecuteAsync(track);
    }

    private async void TrackList_RightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        if ((e.OriginalSource as FrameworkElement)?.DataContext is not Track track) return;
        if (!TrackList.SelectedItems.Contains(track))
            TrackList.SelectedItem = track;
        var selection = Selection();
        var menu = await Controls.TrackContextMenu.BuildAsync(selection.Count > 0 ? selection : new List<Track> { track }, ViewModel.Tracks.ToList());
        menu.ShowAt(TrackList, e.GetPosition(TrackList));
    }

    private void TrackList_ContainerContentChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        // Keep artwork decode cheap: only render when the item is realized in view.
        if (args.InRecycleQueue) args.Handled = true;
    }

    private async void AddFolder_Click(object sender, RoutedEventArgs e)
    {
        var dialogs = App.Services.GetRequiredService<DialogService>();
        var folder = await dialogs.PickFolderAsync("Add to library");
        if (folder is null) return;
        try
        {
            UpdateStates();
            var scanner = App.Services.GetRequiredService<MuurMusic.Core.Library.ILibraryScanner>();
            RescanButton.Visibility = Visibility.Collapsed;
            CancelScanButton.Visibility = Visibility.Visible;
            ScanBar.Visibility = Visibility.Visible;
            await scanner.AddFolderAsync(folder);
        }
        catch (Exception ex)
        {
            App.Services.GetRequiredService<NotificationService>().Error("Could not add folder", ex.Message);
        }
    }
}
