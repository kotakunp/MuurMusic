using Microsoft.UI.Xaml.Controls;

namespace MuurMusic.App.Views;

public partial class GenresPage : Page
{
    protected virtual bool Composers => false;

    protected override async void OnNavigatedTo(Microsoft.UI.Xaml.Navigation.NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        await List.InitializeAsync(Composers);
    }
}
