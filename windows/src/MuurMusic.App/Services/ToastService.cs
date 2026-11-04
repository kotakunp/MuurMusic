using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using MuurMusic.Core.Models;
using MuurMusic.Core.Settings;
using Windows.Graphics;

namespace MuurMusic.App.Services;

/// <summary>
/// Unpackaged-compatible "toast": a small borderless always-on-top window bottom-right that appears on
/// track change (setting: ShowToastOnTrackChange). No MSIX identity or COM activator required.
/// </summary>
public sealed class ToastService
{
    private static readonly TimeSpan Lifetime = TimeSpan.FromMilliseconds(3500);

    private readonly ISettingsService _settings;
    private readonly Queue<(Track Track, string? Artwork)> _pending = new();
    private ToastWindow? _open;

    public ToastService(ISettingsService settings) => _settings = settings;

    public void TrackChanged(Track track, string? artworkPath)
    {
        if (!_settings.Current.ShowToastOnTrackChange || App.IsShuttingDown) return;
        var window = App.CurrentWindow;
        if (window is null) return;
        window.DispatcherQueue.TryEnqueue(() =>
        {
            _pending.Enqueue((track, artworkPath));
            if (_pending.Count > 3) _pending.Dequeue();
            Pump();
        });
    }

    private void Pump()
    {
        if (_open is not null || _pending.Count == 0) return;
        var (track, artwork) = _pending.Dequeue();
        var toast = new ToastWindow(track, artwork);
        _open = toast;
        toast.Closed += (_, _) =>
        {
            _open = null;
            Pump();
        };
        toast.ShowFor(Lifetime);
    }

    private sealed class ToastWindow : Window
    {
        private readonly DispatcherQueueTimer _timer;

        public ToastWindow(Track track, string? artworkPath)
        {
            SystemBackdrop = new MicaBackdrop();
            var root = new Grid
            {
                ColumnSpacing = 12,
                Padding = new Thickness(12),
                Background = new SolidColorBrush(Microsoft.UI.ColorHelper.FromArgb(0xF2, 0x21, 0x1A, 0x3D)),
                CornerRadius = new CornerRadius(14),
                BorderBrush = new SolidColorBrush(Microsoft.UI.ColorHelper.FromArgb(0x40, 0xFF, 0xB2, 0x3F)),
                BorderThickness = new Thickness(1),
            };
            root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(56) });
            root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var art = new Border { Width = 56, Height = 56, CornerRadius = new CornerRadius(8) };
            try
            {
                art.Child = new Image
                {
                    Source = new BitmapImage(new Uri(artworkPath is not null
                        ? artworkPath
                        : System.IO.Path.Combine(AppContext.BaseDirectory, "Assets", "default-artwork.png"))),
                    Stretch = Stretch.UniformToFill,
                };
            }
            catch (Exception) { art.Child = new FontIcon { Glyph = "\uEC4F", FontSize = 22 }; }
            var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Spacing = 2 };
            texts.Children.Add(new TextBlock { Text = "Now playing", Foreground = new SolidColorBrush(Microsoft.UI.ColorHelper.FromArgb(0xFF, 0xA7, 0x9F, 0xC7)), FontSize = 11 });
            texts.Children.Add(new TextBlock { Text = track.DisplayTitle, Foreground = new SolidColorBrush(Microsoft.UI.ColorHelper.FromArgb(0xFF, 0xF5, 0xF2, 0xFF)), FontSize = 14, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = 1 });
            texts.Children.Add(new TextBlock { Text = track.DisplayArtist, Foreground = new SolidColorBrush(Microsoft.UI.ColorHelper.FromArgb(0xFF, 0xA7, 0x9F, 0xC7)), FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = 1 });
            Grid.SetColumn(texts, 1);
            root.Children.Add(art);
            root.Children.Add(texts);
            Content = root;

            var presenter = OverlappedPresenter.Create();
            presenter.IsResizable = false;
            presenter.IsMaximizable = false;
            presenter.IsMinimizable = false;
            presenter.IsAlwaysOnTop = true;
            presenter.SetBorderAndTitleBar(false, false);
            AppWindow.SetPresenter(presenter);
            AppWindow.Resize(new SizeInt32(340, 92));
            Title = "MuurMusic";

            _timer = DispatcherQueue.CreateTimer();
            _timer.Interval = Lifetime;
            _timer.IsRepeating = false;
            _timer.Tick += (_, _) => Close();
        }

        public void ShowFor(TimeSpan duration)
        {
            _timer.Interval = duration;
            var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary);
            var work = area.WorkArea;
            AppWindow.Move(new PointInt32(work.X + work.Width - AppWindow.Size.Width - 16,
                work.Y + work.Height - AppWindow.Size.Height - 16));
            Activate();
            // Keep focus on the main window: the toast never takes input.
            App.CurrentWindow?.Activate();
            _timer.Start();
        }
    }
}
