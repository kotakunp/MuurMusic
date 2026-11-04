using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using MuurMusic.App.Services;
using MuurMusic.App.ViewModels;
using MuurMusic.Core.Models;

namespace MuurMusic.App.Views;

/// <summary>Hosts the history / recently added / most played / favorites lists. Navigation parameter is the kind string.</summary>
public sealed partial class SimpleTrackListPage : Page
{
    public SimpleTrackListPage()
    {
        InitializeComponent();
        ViewModel = App.Services.GetRequiredService<SimpleTrackListViewModel>();
    }

    public SimpleTrackListViewModel ViewModel { get; }

    protected override async void OnNavigatedTo(Microsoft.UI.Xaml.Navigation.NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        var kind = e.Parameter as string
            ?? App.Services.GetRequiredService<NavigationService>().CurrentKey
            ?? "recent";
        await ViewModel.LoadAsync(kind);
        TrackRows.ItemsSource = ViewModel.Tracks.ToList();
        // TrackRows binds a snapshot; re-snapshot after collection changes.
        ViewModel.Tracks.CollectionChanged += (_, _) => TrackRows.ItemsSource = ViewModel.Tracks.ToList();
    }

    private async void TrackRows_PlayRequested(object? sender, Track track) => await ViewModel.PlayAsync(track);
    private async void History_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is PlayHistoryEntry entry) await ViewModel.PlayHistoryAsync(entry);
    }
    private async void PlayAll_Click(object sender, RoutedEventArgs e) => await ViewModel.PlayAsync(null);
    private async void ClearHistory_Click(object sender, RoutedEventArgs e)
    {
        if (await App.Services.GetRequiredService<DialogService>().ConfirmAsync("Clear history", "Forget everything you've played? Play counts stay.", "Clear"))
            await ViewModel.ClearHistoryCommand.ExecuteAsync(null);
    }
}
