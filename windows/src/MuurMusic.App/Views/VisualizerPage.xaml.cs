using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml.Controls;
using MuurMusic.App.Controls;
using MuurMusic.App.ViewModels;

namespace MuurMusic.App.Views;

public sealed partial class VisualizerPage : Page
{
    private bool _ready;

    public VisualizerPage()
    {
        InitializeComponent();
        ViewModel = App.Services.GetRequiredService<VisualizerViewModel>();
        foreach (var name in VisualizerViewModel.PresetNames)
            PresetBox.Items.Add(new ComboBoxItem { Content = name, Tag = name });
    }

    public VisualizerViewModel ViewModel { get; }

    protected override void OnNavigatedTo(Microsoft.UI.Xaml.Navigation.NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        PresetBox.SelectedIndex = (int)ViewModel.Preset;
        _ready = true;
        ViewModel.Start();
    }

    protected override void OnNavigatedFrom(Microsoft.UI.Xaml.Navigation.NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        ViewModel.Stop();
    }

    private void PresetBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_ready && PresetBox.SelectedItem is ComboBoxItem { Tag: string tag })
            ViewModel.SelectPresetCommand.Execute(tag);
    }
}
