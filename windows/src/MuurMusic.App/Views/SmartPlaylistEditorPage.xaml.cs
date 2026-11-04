using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using MuurMusic.App.Services;
using MuurMusic.App.ViewModels;
using MuurMusic.Core.Models;

namespace MuurMusic.App.Views;

public sealed partial class SmartPlaylistEditorPage : Page
{
    private bool _ready;

    public SmartPlaylistEditorPage()
    {
        InitializeComponent();
        ViewModel = App.Services.GetRequiredService<SmartPlaylistEditorViewModel>();
    }

    public SmartPlaylistEditorViewModel ViewModel { get; }

    protected override void OnNavigatedTo(Microsoft.UI.Xaml.Navigation.NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        if (e.Parameter is Playlist playlist) ViewModel.LoadFrom(playlist);
        else if (e.Parameter is string name) ViewModel.NewDefinition(name);
        Bindings.Update();
        // Reflect the persisted sort in the combo.
        foreach (ComboBoxItem item in SortBox.Items)
            if ((item.Tag as string ?? "") == (ViewModel.SortText ?? "")) { SortBox.SelectedItem = item; break; }
        _ready = true;
    }

    private void SortBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_ready && SortBox.SelectedItem is ComboBoxItem item)
            ViewModel.SortText = item.Tag as string ?? "";
    }

    private void AddRule_Click(object sender, RoutedEventArgs e) => ViewModel.AddRuleCommand.Execute(null);

    private async void Save_Click(object sender, RoutedEventArgs e)
    {
        if (await ViewModel.SaveAsync() is { } playlist)
        {
            App.Services.GetRequiredService<NotificationService>().Success("Playlist saved", playlist.Name);
            App.Services.GetRequiredService<NavigationService>().Navigate("playlist", playlist.Id);
        }
    }
}
