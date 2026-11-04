using System.Runtime.InteropServices;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using MuurMusic.App.Services;
using MuurMusic.Core.Settings;
using Windows.System;
using WinRT.Interop;

namespace MuurMusic.App;

public sealed partial class MainWindow : Window
{
    private bool _reallyClosing;
    private bool _taskbarInitialized;

    public MainWindow()
    {
        InitializeComponent();

        Title = "MuurMusic";
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBarGrid);

        AppWindow.Title = "MuurMusic";
        var iconPath = System.IO.Path.Combine(AppContext.BaseDirectory, "Assets", "MuurMusic.ico");
        if (System.IO.File.Exists(iconPath)) AppWindow.SetIcon(iconPath);
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.IsResizable = true;
            presenter.IsMaximizable = true;
        }
        if (AppWindow.Size.Width < 1100 || AppWindow.Size.Height < 700)
            AppWindow.Resize(new Windows.Graphics.SizeInt32(1180, 760));

        var nav = App.Services.GetRequiredService<NavigationService>();
        nav.Attach(ContentFrame);
        nav.Navigated += (_, key) => SyncNavSelection(key);

        var notifications = App.Services.GetRequiredService<NotificationService>();
        notifications.CurrentChanged += (_, n) => ShowNotification(n);

        AppWindow.Closing += OnClosing;
        RootGrid.PreviewKeyDown += OnPreviewKeyDown;
        Activated += OnActivatedOnce;

        // Start page from settings.
        var settings = App.Services.GetRequiredService<ISettingsService>();
        var start = settings.Current.TabsOrder.Count > 0 ? settings.Current.TabsOrder[0] : "Songs";
        var key = start.ToLowerInvariant() is var k && nav.CanNavigate(k) ? k : "songs";
        nav.Navigate(key);
    }

    private void OnActivatedOnce(object sender, WindowActivatedEventArgs args)
    {
        Activated -= OnActivatedOnce;
        if (_taskbarInitialized) return;
        _taskbarInitialized = true;
        var taskbar = App.Services.GetRequiredService<TaskbarService>();
        taskbar.Initialize(App.MainWindowHandle);
        _ = taskbar.TryInitializeJumpListAsync();
        App.Services.GetRequiredService<ThemeService>().ApplyCurrent();
    }

    private void SyncNavSelection(string key)
    {
        if (key == "settings")
        {
            Nav.SelectedItem = Nav.SettingsItem;
            return;
        }
        foreach (var item in Nav.MenuItems.OfType<NavigationViewItem>())
        {
            if (item.Tag is string tag && tag == key)
            {
                Nav.SelectedItem = item;
                return;
            }
        }
    }

    private void Nav_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        var nav = App.Services.GetRequiredService<NavigationService>();
        if (args.IsSettingsSelected)
        {
            if (nav.CurrentKey != "settings") nav.Navigate("settings");
            return;
        }
        if (args.SelectedItem is NavigationViewItem { Tag: string tag } && nav.CurrentKey != tag)
            nav.Navigate(tag);
    }

    private void SearchBox_QuerySubmitted(AutoSuggestBox sender, AutoSuggestBoxQuerySubmittedEventArgs args)
    {
        var query = args.ChosenSuggestion is string chosen ? chosen : args.QueryText;
        if (!string.IsNullOrWhiteSpace(query))
            App.Services.GetRequiredService<NavigationService>().Navigate("search", query.Trim());
    }

    private async void SearchBox_TextChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        if (args.Reason != AutoSuggestionBoxTextChangeReason.UserInput) return;
        var text = sender.Text;
        var suggestions = await ViewModels.SearchViewModel.SuggestAsync(text);
        if (sender.Text == text) sender.ItemsSource = suggestions;
    }

    private void SearchBox_SuggestionChosen(AutoSuggestBox sender, AutoSuggestBoxSuggestionChosenEventArgs args)
    {
        if (args.SelectedItem is string s) sender.Text = s;
    }

    private void ShowNotification(AppNotification? n)
    {
        if (n is null)
        {
            NotificationBar.IsOpen = false;
            return;
        }
        NotificationBar.Title = n.Title;
        NotificationBar.Message = n.Message ?? "";
        NotificationBar.Severity = n.Kind switch
        {
            NotificationKind.Success => InfoBarSeverity.Success,
            NotificationKind.Warning => InfoBarSeverity.Warning,
            NotificationKind.Error => InfoBarSeverity.Error,
            _ => InfoBarSeverity.Informational,
        };
        NotificationBar.IsOpen = true;
        n.IsOpen = true;
    }

    private void NotificationBar_Closed(InfoBar sender, InfoBarClosedEventArgs args) =>
        App.Services.GetRequiredService<NotificationService>().DismissCurrent();

    private void OnPreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var focused = FocusManager.GetFocusedElement(RootGrid.XamlRoot);
        var typing = focused is TextBox or AutoSuggestBox or PasswordBox or RichEditBox;

        var ctrl = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        var playback = App.Services.GetRequiredService<MuurMusic.Audio.Playback.IPlaybackService>();

        if (e.Key == VirtualKey.Space && !typing)
        {
            e.Handled = true;
            _ = playback.TogglePlayPauseAsync();
        }
        else if (ctrl && e.Key == VirtualKey.Right)
        {
            e.Handled = true;
            _ = playback.NextAsync();
        }
        else if (ctrl && e.Key == VirtualKey.Left)
        {
            e.Handled = true;
            _ = playback.PreviousAsync();
        }
        else if (ctrl && e.Key == VirtualKey.Up)
        {
            e.Handled = true;
            playback.Volume = Math.Min(1, playback.Volume + 0.05);
        }
        else if (ctrl && e.Key == VirtualKey.Down)
        {
            e.Handled = true;
            playback.Volume = Math.Max(0, playback.Volume - 0.05);
        }
        else if (ctrl && e.Key == VirtualKey.F)
        {
            e.Handled = true;
            SearchBox.Focus(FocusState.Programmatic);
        }
    }

    public void BringToForeground()
    {
        if (AppWindow.Presenter is OverlappedPresenter p && p.State == OverlappedPresenterState.Minimized)
            p.Restore();
        AppWindow.Show(activateWindow: true);
        var hwnd = App.MainWindowHandle;
        if (hwnd != IntPtr.Zero)
        {
            ShowWindow(hwnd, SwRestore);
            SetForegroundWindow(hwnd);
        }
    }

    private async void OnClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (_reallyClosing) return;
        args.Cancel = true;
        await App.ShutdownAsync();
        _reallyClosing = true;
        Close();
    }

    private const int SwRestore = 9;
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hWnd);
}
