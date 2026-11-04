using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using MuurMusic.App.ViewModels;

namespace MuurMusic.App.Controls;

public sealed partial class QueueFlyoutContent : UserControl
{
    private int _dragFrom = -1;

    public QueueFlyoutContent()
    {
        InitializeComponent();
        ViewModel = App.Services.GetRequiredService<PlayerBarViewModel>().Queue;
    }

    public QueueViewModel ViewModel { get; }

    private void QueueList_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is QueueEntryItemViewModel item)
            _ = ViewModel.PlayEntryCommand.ExecuteAsync(item);
    }

    private void RemoveEntry_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: QueueEntryItemViewModel item })
            _ = ViewModel.RemoveEntryCommand.ExecuteAsync(item);
    }

    private void QueueList_DragItemsStarting(object sender, DragItemsStartingEventArgs e)
    {
        ViewModel.BeginReorder();
        _dragFrom = e.Items.FirstOrDefault() is QueueEntryItemViewModel item ? ViewModel.Items.IndexOf(item) : -1;
    }

    private void QueueList_DragItemsCompleted(ListViewBase sender, DragItemsCompletedEventArgs args)
    {
        var dragged = args.Items.FirstOrDefault() as QueueEntryItemViewModel;
        var to = dragged is null ? -1 : ViewModel.Items.IndexOf(dragged);
        // The ListView already moved the item inside the collection when it was last removed first;
        // the drop index reported by the collection is the final position.
        ViewModel.EndReorder(_dragFrom, to);
        _dragFrom = -1;
    }

    private async void SavePlaylist_Click(object sender, RoutedEventArgs e)
    {
        var name = PlaylistNameBox.Text;
        PlaylistNameBox.Text = "";
        await ViewModel.SaveAsPlaylistCommand.ExecuteAsync(name);
    }

    private void PlaylistNameBox_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Enter)
        {
            e.Handled = true;
            SavePlaylist_Click(sender, e);
        }
    }
}
