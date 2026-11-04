using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using MuurMusic.App.Services;
using MuurMusic.App.ViewModels;
using MuurMusic.Core.Models;

namespace MuurMusic.App.Views;

public sealed partial class TrackListPage : Page
{
    public TrackListPage()
    {
        InitializeComponent();
        ViewModel = App.Services.GetRequiredService<TrackListViewModel>();
    }

    public TrackListViewModel ViewModel { get; }

    protected override async void OnNavigatedTo(Microsoft.UI.Xaml.Navigation.NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        if (e.Parameter is TrackListNavigation nav)
        {
            await ViewModel.LoadAsync(nav);
            TrackRows.ItemsSource = ViewModel.Tracks.ToList();
        }
    }

    private async void TrackRows_PlayRequested(object? sender, Track track) => await ViewModel.PlayAsync(track);
    private async void Play_Click(object sender, RoutedEventArgs e) => await ViewModel.PlayAsync(null);
}
