using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using MuurMusic.App.Services;
using MuurMusic.App.ViewModels;
using MuurMusic.Core.Library;
using MuurMusic.Core.Models;

namespace MuurMusic.App.Views;

public sealed partial class SourcesPage : Page
{
    public SourcesPage()
    {
        InitializeComponent();
        ViewModel = App.Services.GetRequiredService<SourcesViewModel>();
        ViewModel.OnBrowse = item =>
        {
            App.Services.GetRequiredService<NavigationService>().Navigate("source", item.Id);
            return Task.CompletedTask;
        };
        ViewModel.OnEdit = EditSourceAsync;
        ViewModel.OnAddDiscovered = AddDiscoveredAsync;
        ViewModel.OnBrowseDrive = drive =>
        {
            App.Services.GetRequiredService<NavigationService>().Navigate("files", drive.Root);
            return Task.CompletedTask;
        };
        ViewModel.OnAddDriveToLibrary = async drive =>
        {
            await App.Services.GetRequiredService<ILibraryScanner>().AddFolderAsync(drive.Root);
            App.Services.GetRequiredService<NotificationService>().Success("Folder added", $"{drive.Name} is now in your library.");
        };
        ViewModel.OnConfirmRemove = async item =>
            await App.Services.GetRequiredService<DialogService>().ConfirmAsync(
                "Remove source", $"Remove \\u201C{item.Name}\\u201D? Downloaded offline copies stay on disk.", "Remove");
        BuildCatalogButtons();
    }

    public SourcesViewModel ViewModel { get; }

    private void BuildCatalogButtons()
    {
        foreach (var entry in SourceCatalog.Entries)
        {
            var button = new Button();
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, $"Add {entry.Label}");
            button.Content = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 6,
                Children =
                {
                    new FontIcon { Glyph = entry.Glyph, FontSize = 13 },
                    new TextBlock { Text = entry.Label },
                },
            };
            var kind = entry.Kind;
            button.Click += async (_, _) => await AddSourceAsync(kind);
            (entry.Group switch
            {
                "Cloud" => CloudButtons,
                "Media servers" => MediaButtons,
                "Servers & network" => ServerButtons,
                _ => DeviceButtons,
            }).Children.Add(button);
        }
    }

    private async Task AddSourceAsync(SourceKind kind)
    {
        var result = await SourceEditDialog.ShowForAsync(kind);
        if (result is null) return;
        // Credentials kinds were already tested inside the dialog; OAuth sources get tested by the manager now.
        await ViewModel.AddAsync(result.Config, result.Secrets, test: SourceCatalog.IsOAuth(kind));
    }

    private async Task EditSourceAsync(SourceItemViewModel item)
    {
        var result = await SourceEditDialog.ShowForAsync(item.Kind, item.Source.Config);
        if (result is null) return;
        await ViewModel.UpdateAsync(result.Config, result.Secrets);
    }

    private async Task AddDiscoveredAsync(DiscoveredItem item)
    {
        var result = await SourceEditDialog.ShowForAsync(item.Server);
        if (result is null) return;
        await ViewModel.AddAsync(result.Config, result.Secrets, test: false);
    }

    private async void Scan_Click(object sender, RoutedEventArgs e) => await ViewModel.ScanNetworkCommand.ExecuteAsync(null);
}
