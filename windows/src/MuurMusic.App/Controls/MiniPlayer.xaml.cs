using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using MuurMusic.App.Services;
using MuurMusic.App.ViewModels;
using Windows.System;

namespace MuurMusic.App.Controls;

/// <summary>The persistent bottom transport bar.</summary>
public sealed partial class MiniPlayer : UserControl
{
    private bool _draggingSeek;

    public MiniPlayer()
    {
        InitializeComponent();
        ViewModel = App.Services.GetRequiredService<PlayerBarViewModel>();
        UpdateArtwork();
        ViewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(PlayerBarViewModel.ArtworkPath) or nameof(PlayerBarViewModel.HasTrack)) UpdateArtwork();
        };
    }

    public PlayerBarViewModel ViewModel { get; }

    private void UpdateArtwork()
    {
        var path = ViewModel.ArtworkPath ?? System.IO.Path.Combine(AppContext.BaseDirectory, "Assets", "default-artwork.png");
        try { ArtworkImage.Source = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(new Uri(path)); }
        catch (Exception) { ArtworkImage.Source = null; }
    }

    private void ArtworkImage_Failed(object sender, ExceptionRoutedEventArgs e)
    {
        try { ArtworkImage.Source = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(new Uri(System.IO.Path.Combine(AppContext.BaseDirectory, "Assets", "default-artwork.png"))); }
        catch (Exception) { }
    }

    private void SeekSlider_PointerPressed(object sender, PointerRoutedEventArgs e)
    {
        _draggingSeek = true;
        ViewModel.BeginSeek();
    }

    private void SeekSlider_PointerCaptureLost(object sender, PointerRoutedEventArgs e)
    {
        if (!_draggingSeek) return;
        _draggingSeek = false;
        ViewModel.EndSeek(SeekSlider.Value);
    }

    private void SeekSlider_ValueChanged(object sender, Microsoft.UI.Xaml.Controls.Primitives.RangeBaseValueChangedEventArgs e)
    {
        // Keyboard-driven changes (slider focused, no pointer drag) commit immediately.
        if (!_draggingSeek && SeekSlider.FocusState != FocusState.Unfocused && Math.Abs(e.NewValue - e.OldValue) > 0.001)
            ViewModel.EndSeek(e.NewValue);
    }

    private void NowPlaying_Click(object sender, RoutedEventArgs e) =>
        App.Services.GetRequiredService<NavigationService>().Navigate("nowplaying");

    private void CastFlyout_Opened(object sender, object e)
    {
        if (ViewModel.CastDevices.Count == 0 && !ViewModel.IsCasting)
            _ = ViewModel.DiscoverCastDevicesCommand.ExecuteAsync(null);
    }
}
