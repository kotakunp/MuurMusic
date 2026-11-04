using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using MuurMusic.App.Services;
using MuurMusic.App.ViewModels;

namespace MuurMusic.App.Views;

public sealed partial class NowPlayingPage : Page
{
    private readonly DispatcherTimer _spinTimer = new() { Interval = TimeSpan.FromMilliseconds(33) };
    private bool _ready;

    public NowPlayingPage()
    {
        InitializeComponent();
        ViewModel = App.Services.GetRequiredService<NowPlayingViewModel>();
        _spinTimer.Tick += (_, _) =>
        {
            if (ViewModel is { IsPlaying: true, ShowVinylStyle: true })
                VinylRotation.Angle = (VinylRotation.Angle + 1.1) % 360;
        };
        ViewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(NowPlayingViewModel.ActiveLineIndex))
                ScrollActiveLine();
            if (e.PropertyName is nameof(NowPlayingViewModel.IsPlaying) or nameof(NowPlayingViewModel.ShowVinylStyle))
                UpdateSpin();
        };
    }

    public NowPlayingViewModel ViewModel { get; }

    protected override void OnNavigatedTo(Microsoft.UI.Xaml.Navigation.NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        StyleBox.SelectedIndex = ViewModel.StyleKey switch { "Vinyl" => 1, "Visualizer" => 2, _ => 0 };
        _ready = true;
        ViewModel.Start();
        UpdateSpin();
    }

    protected override void OnNavigatedFrom(Microsoft.UI.Xaml.Navigation.NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        _spinTimer.Stop();
        ViewModel.Stop();
    }

    private void UpdateSpin()
    {
        if (ViewModel is { IsPlaying: true, ShowVinylStyle: true }) _spinTimer.Start();
        else _spinTimer.Stop();
    }

    private void ScrollActiveLine()
    {
        var idx = ViewModel.ActiveLineIndex;
        if (idx < 0 || idx >= ViewModel.Lines.Count) return;
        // Center-ish: bring a couple of lines ahead into view too.
        var target = Math.Min(idx + 2, ViewModel.Lines.Count - 1);
        LyricsList.ScrollIntoView(ViewModel.Lines[target], ScrollIntoViewAlignment.Leading);
        LyricsList.ScrollIntoView(ViewModel.Lines[Math.Max(0, idx - 2)], ScrollIntoViewAlignment.Leading);
        LyricsList.ScrollIntoView(ViewModel.Lines[idx]);
    }

    private void StyleBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_ready || StyleBox.SelectedItem is not ComboBoxItem { Content: string style }) return;
        ViewModel.ApplyStyle(style);
        UpdateSpin();
    }

    private void VinylStage_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (sender is FrameworkElement stage)
        {
            VinylRotation.CenterX = stage.ActualWidth / 2;
            VinylRotation.CenterY = stage.ActualHeight / 2;
        }
    }

    private async void LyricsList_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is LyricLineViewModel line) await ViewModel.SeekToLineAsync(line);
    }

    private async void FindOnline_Click(object sender, RoutedEventArgs e) => await ViewModel.FindOnlineCommand.ExecuteAsync(null);
    private async void OffsetUp_Click(object sender, RoutedEventArgs e) => await ViewModel.NudgeOffsetCommand.ExecuteAsync(100);
    private async void OffsetDown_Click(object sender, RoutedEventArgs e) => await ViewModel.NudgeOffsetCommand.ExecuteAsync(-100);

    private async void UpNext_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is UpNextItem item) await ViewModel.PlayUpNextAsync(item);
    }
}
