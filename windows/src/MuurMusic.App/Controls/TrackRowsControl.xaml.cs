using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using MuurMusic.Core.Models;

namespace MuurMusic.App.Controls;

/// <summary>Compact multi-select track list with double-tap play and the shared context menu.</summary>
public sealed partial class TrackRowsControl : UserControl
{
    public TrackRowsControl() => InitializeComponent();

    public static readonly DependencyProperty ItemsSourceProperty =
        DependencyProperty.Register(nameof(ItemsSource), typeof(IReadOnlyList<Track>), typeof(TrackRowsControl),
            new PropertyMetadata(null, (d, _) => ((TrackRowsControl)d).OnItemsChanged()));

    public IReadOnlyList<Track>? ItemsSource
    {
        get => (IReadOnlyList<Track>?)GetValue(ItemsSourceProperty);
        set => SetValue(ItemsSourceProperty, value);
    }

    /// <summary>Double-tap / Enter play request; argument is the tapped track.</summary>
    public event EventHandler<Track>? PlayRequested;

    public IReadOnlyList<Track> Selection => List.SelectedItems.Cast<Track>().ToList();

    private void OnItemsChanged() => List.ItemsSource = ItemsSource;

    private void List_DoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        if ((e.OriginalSource as FrameworkElement)?.DataContext is Track track)
            PlayRequested?.Invoke(this, track);
    }

    private async void List_RightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        if ((e.OriginalSource as FrameworkElement)?.DataContext is not Track track) return;
        if (!List.SelectedItems.Contains(track)) List.SelectedItem = track;
        var selection = Selection;
        var menu = await TrackContextMenu.BuildAsync(
            selection.Count > 0 ? selection : new List<Track> { track },
            ItemsSource?.ToList() ?? new List<Track>());
        menu.ShowAt(List, e.GetPosition(List));
    }
}
