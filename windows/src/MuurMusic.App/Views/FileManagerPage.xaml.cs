using System.ComponentModel;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using MuurMusic.App.Services;
using MuurMusic.App.ViewModels;

namespace MuurMusic.App.Views;

public sealed partial class FileManagerPage : Page, INotifyPropertyChanged
{
    private bool _hasSelection;

    public event PropertyChangedEventHandler? PropertyChanged;

    public bool HasSelection
    {
        get => _hasSelection;
        set { if (_hasSelection == value) return; _hasSelection = value; PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(HasSelection))); }
    }

    public FileManagerPage()
    {
        InitializeComponent();
        ViewModel = App.Services.GetRequiredService<FileManagerViewModel>();
    }

    public FileManagerViewModel ViewModel { get; }

    private IReadOnlyList<BrowserItemViewModel> Selection => List.SelectedItems.Cast<BrowserItemViewModel>().ToList();

    protected override async void OnNavigatedTo(Microsoft.UI.Xaml.Navigation.NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        await ViewModel.LoadAsync(e.Parameter);
    }

    private async void List_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is BrowserItemViewModel item) await ViewModel.OpenAsync(item);
    }

    private void List_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        HasSelection = List.SelectedItems.Count > 0;
        SelectionText.Text = $"{List.SelectedItems.Count} selected";
    }

    private void List_RightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        if ((e.OriginalSource as FrameworkElement)?.DataContext is not BrowserItemViewModel item) return;
        if (!List.SelectedItems.Contains(item)) List.SelectedItem = item;
        var menu = new MenuFlyout();
        if (item.IsPlayable)
        {
            var play = new MenuFlyoutItem { Text = "Play", Icon = new FontIcon { Glyph = "\uE768" } };
            play.Click += async (_, _) => await ViewModel.PlayAsync(item);
            menu.Items.Add(play);
            menu.Items.Add(new MenuFlyoutSeparator());
        }
        if (ViewModel.CanWrite)
        {
            var rename = new MenuFlyoutItem { Text = "Rename", Icon = new FontIcon { Glyph = "\uE70F" } };
            rename.Click += async (_, _) => await ViewModel.RenameAsync(item);
            var del = new MenuFlyoutItem { Text = "Delete", Icon = new FontIcon { Glyph = "\uE74D" } };
            del.Click += async (_, _) => await ViewModel.DeleteAsync(Selection.Count > 0 ? Selection : new[] { item });
            menu.Items.Add(rename);
            menu.Items.Add(del);
        }
        var export = new MenuFlyoutItem { Text = "Export to folder", Icon = new FontIcon { Glyph = "\uE896" } };
        export.Click += async (_, _) => await ViewModel.ExportAsync(Selection.Count > 0 ? Selection : new[] { item });
        menu.Items.Add(export);
        menu.ShowAt(List, e.GetPosition(List));
    }

    private async void Up_Click(object sender, RoutedEventArgs e) => await ViewModel.GoUpCommand.ExecuteAsync(null);
    private async void Refresh_Click(object sender, RoutedEventArgs e) => await ViewModel.RefreshCommand.ExecuteAsync(null);
    private async void PlayFolder_Click(object sender, RoutedEventArgs e) => await ViewModel.PlayFolderCommand.ExecuteAsync(null);
    private async void NewFolder_Click(object sender, RoutedEventArgs e) => await ViewModel.NewFolderCommand.ExecuteAsync(null);
    private async void Upload_Click(object sender, RoutedEventArgs e) => await ViewModel.UploadFilesCommand.ExecuteAsync(null);
    private async void AddToLibrary_Click(object sender, RoutedEventArgs e) => await ViewModel.AddFolderToLibraryCommand.ExecuteAsync(null);

    private async void PlaySelection_Click(object sender, RoutedEventArgs e)
    {
        foreach (var item in Selection.Where(i => i.IsPlayable).Take(1)) await ViewModel.PlayAsync(item);
    }

    private async void RenameSelection_Click(object sender, RoutedEventArgs e) => await ViewModel.RenameAsync(Selection.FirstOrDefault());
    private async void MoveSelection_Click(object sender, RoutedEventArgs e) => await ViewModel.MoveOrCopyAsync(Selection, move: true);
    private async void CopySelection_Click(object sender, RoutedEventArgs e) => await ViewModel.MoveOrCopyAsync(Selection, move: false);
    private async void ExportSelection_Click(object sender, RoutedEventArgs e) => await ViewModel.ExportAsync(Selection);
    private async void DeleteSelection_Click(object sender, RoutedEventArgs e) => await ViewModel.DeleteAsync(Selection);
}
