using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using MuurMusic.App.Services;
using MuurMusic.App.ViewModels;
using MuurMusic.Core.Models;

namespace MuurMusic.App.Views;

public sealed partial class AlbumDetailPage : Page
{
    public AlbumDetailPage()
    {
        InitializeComponent();
        ViewModel = App.Services.GetRequiredService<AlbumDetailViewModel>();
    }

    public AlbumDetailViewModel ViewModel { get; }

    protected override async void OnNavigatedTo(Microsoft.UI.Xaml.Navigation.NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        if (e.Parameter is string albumKey)
        {
            await ViewModel.LoadAsync(albumKey);
            TrackRows.ItemsSource = ViewModel.Tracks.ToList();
        }
    }

    private async void TrackRows_PlayRequested(object? sender, Track track) => await ViewModel.PlayAsync(track);
    private async void Play_Click(object sender, RoutedEventArgs e) => await ViewModel.PlayAsync(null);
    private async void Shuffle_Click(object sender, RoutedEventArgs e) => await ViewModel.PlayAsync(null, shuffle: true);
    private void Enqueue_Click(object sender, RoutedEventArgs e) => ViewModel.EnqueueCommand.Execute(false);
    private async void Download_Click(object sender, RoutedEventArgs e) => await ViewModel.DownloadCommand.ExecuteAsync(null);
}
