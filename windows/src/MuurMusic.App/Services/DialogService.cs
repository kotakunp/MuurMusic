using Microsoft.UI.Xaml;
using Windows.Storage.Pickers;
using Microsoft.UI.Xaml.Controls;
using WinRT.Interop;

namespace MuurMusic.App.Services;

/// <summary>ContentDialog + file/folder picker helpers bound to the main window.</summary>
public sealed class DialogService
{
    private static Microsoft.UI.Xaml.XamlRoot? Root => App.CurrentWindow?.Content?.XamlRoot;

    private static T InitPicker<T>(T picker)
    {
        InitializeWithWindow.Initialize(picker, App.MainWindowHandle);
        return picker;
    }

    public async Task<ContentDialogResult> ShowAsync(ContentDialog dialog)
    {
        dialog.XamlRoot = Root ?? throw new InvalidOperationException("No window to host the dialog.");
        return await dialog.ShowAsync();
    }

    public async Task<bool> ConfirmAsync(string title, string message, string confirmText = "OK")
    {
        var d = new ContentDialog
        {
            Title = title,
            Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap, MaxWidth = 420 },
            PrimaryButtonText = confirmText,
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        return await ShowAsync(d) == ContentDialogResult.Primary;
    }

    /// <summary>Single-line text prompt; null when canceled.</summary>
    public async Task<string?> PromptAsync(string title, string label, string initial = "", string confirmText = "Save")
    {
        var box = new TextBox { Text = initial, PlaceholderText = label, MinWidth = 320 };
        box.SelectAll();
        var d = new ContentDialog
        {
            Title = title,
            Content = box,
            PrimaryButtonText = confirmText,
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        var result = await ShowAsync(d);
        var text = box.Text.Trim();
        return result == ContentDialogResult.Primary && text.Length > 0 ? text : null;
    }

    public async Task<string?> PickFolderAsync(string buttonText = "Choose")
    {
        var picker = InitPicker(new FolderPicker { SuggestedStartLocation = PickerLocationId.MusicLibrary, CommitButtonText = buttonText });
        picker.FileTypeFilter.Add("*");
        var folder = await picker.PickSingleFolderAsync();
        return folder?.Path;
    }

    public async Task<string?> PickOpenFileAsync(string buttonText = "Open", params string[] extensions)
    {
        var picker = InitPicker(new FileOpenPicker { SuggestedStartLocation = PickerLocationId.MusicLibrary, CommitButtonText = buttonText });
        foreach (var e in extensions.Length > 0 ? extensions : new[] { "*" }) picker.FileTypeFilter.Add(e);
        var file = await picker.PickSingleFileAsync();
        return file?.Path;
    }

    public async Task<IReadOnlyList<string>> PickOpenFilesAsync(string buttonText = "Open", params string[] extensions)
    {
        var picker = InitPicker(new FileOpenPicker { SuggestedStartLocation = PickerLocationId.MusicLibrary, CommitButtonText = buttonText });
        foreach (var e in extensions.Length > 0 ? extensions : new[] { "*" }) picker.FileTypeFilter.Add(e);
        var files = await picker.PickMultipleFilesAsync();
        return files.Select(f => f.Path).ToList();
    }

    public async Task<string?> PickSaveFileAsync(string suggestedName, string defaultExtension, params (string Label, string Extension)[] choices)
    {
        var picker = InitPicker(new FileSavePicker { SuggestedStartLocation = PickerLocationId.MusicLibrary, SuggestedFileName = suggestedName });
        foreach (var (label, ext) in choices) picker.FileTypeChoices.Add(label, new[] { ext });
        if (choices.Length == 0) picker.FileTypeChoices.Add("File", new[] { defaultExtension });
        picker.DefaultFileExtension = defaultExtension;
        var file = await picker.PickSaveFileAsync();
        return file?.Path;
    }
}
