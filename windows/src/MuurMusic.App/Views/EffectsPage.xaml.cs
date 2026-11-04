using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml.Controls;
using MuurMusic.App.Services;
using MuurMusic.App.ViewModels;

namespace MuurMusic.App.Views;

public sealed partial class EffectsPage : Page
{
    public EffectsPage()
    {
        InitializeComponent();
        ViewModel = App.Services.GetRequiredService<EffectsViewModel>();
    }

    public EffectsViewModel ViewModel { get; }

    protected override void OnNavigatedTo(Microsoft.UI.Xaml.Navigation.NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        // Reflect edits made on the DSP page since the last visit.
        ViewModel.Rebuild();
        Bindings.Update();
    }
}
