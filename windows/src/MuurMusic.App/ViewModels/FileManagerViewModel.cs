using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using MuurMusic.App.Services;
using MuurMusic.Audio.Playback;
using MuurMusic.Core.Downloads;
using MuurMusic.Core.Models;
using MuurMusic.Core.Sources;

namespace MuurMusic.App.ViewModels;

/// <summary>
/// File manager: browse any source (local drive, server, cloud) with multi-select file operations.
/// Move/copy use real filesystem operations for local URIs; remote sources fall back to download+upload.
/// </summary>
public sealed partial class FileManagerViewModel : ObservableObject
{
    private readonly ISourceManager _sources;
    private readonly IPlaybackService _playback;
    private readonly IDownloadManager _downloads;
    private readonly NotificationService _notifications;
    private readonly DialogService _dialogs;
    private readonly Stack<string> _back = new();
    private IMusicSource? _source;
    private string _currentUri = "";
    private string _localRoot = "";

    public FileManagerViewModel(ISourceManager sources, IPlaybackService playback, IDownloadManager downloads, NotificationService notifications, DialogService dialogs)
    {
        _sources = sources;
        _playback = playback;
        _downloads = downloads;
        _notifications = notifications;
        _dialogs = dialogs;
    }

    public ObservableCollection<BrowserItemViewModel> Items { get; } = new();

    [ObservableProperty] private string _title = "Files";
    [ObservableProperty] private string _currentFolderName = "";
    [ObservableProperty] private bool _canGoUp;
    [ObservableProperty] private bool _isLoading;
    [ObservableProperty] private string _error = "";
    [ObservableProperty] private bool _canWrite;
    [ObservableProperty] private bool _canUpload;
    [ObservableProperty] private bool _isLocal;

    public bool ShowEmpty => !IsLoading && Items.Count == 0 && Error.Length == 0;
    public bool HasError => Error.Length > 0;
    partial void OnIsLoadingChanged(bool value) => OnPropertyChanged(nameof(ShowEmpty));
    partial void OnErrorChanged(string value)
    {
        OnPropertyChanged(nameof(HasError));
        OnPropertyChanged(nameof(ShowEmpty));
    }

    public SourceCapabilities Caps => _source?.Capabilities ?? SourceCapabilities.Browse;

    /// <summary>Param: a local path string or a Guid source id.</summary>
    public async Task LoadAsync(object? param)
    {
        _source = param switch
        {
            Guid id => _sources.Get(id),
            string => _sources.LocalSource,
            null => _sources.LocalSource,
            _ => null,
        };
        if (_source is null) { Error = "Source not found."; return; }

        IsLocal = _source.Config.Kind == SourceKind.Local;
        CanWrite = _source.Capabilities.HasFlag(SourceCapabilities.CreateFolder);
        CanUpload = _source.Capabilities.HasFlag(SourceCapabilities.Upload);

        string? startUri = null;
        if (param is string p && p.Length > 0)
        {
            startUri = SourceUris.FromLocalPath(p);
            _localRoot = p;
            Title = Path.GetFileName(p.TrimEnd('\\')) is { Length: > 0 } n ? n : p;
        }
        else
        {
            Title = _source.Config.Name;
            _localRoot = "";
        }
        await ShowFolderAsync(startUri);
    }

    private async Task ShowFolderAsync(string? uri)
    {
        if (_source is null) return;
        IsLoading = true;
        Error = "";
        try
        {
            var items = await _source.ListAsync(uri);
            Items.Clear();
            foreach (var item in items
                         .OrderByDescending(i => i.IsFolder)
                         .ThenBy(i => i.Name, StringComparer.CurrentCultureIgnoreCase))
                Items.Add(new BrowserItemViewModel { Item = item, Source = _source });
            _currentUri = uri ?? "";
            CanGoUp = _back.Count > 0 || (IsLocal && _localRoot.Length > 0 && uri is not null
                && SourceUris.TryGetLocalPath(uri, out var lp) && !string.Equals(lp.TrimEnd('\\'), _localRoot.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase));
        }
        catch (Exception ex)
        {
            Error = ex.Message;
        }
        finally
        {
            IsLoading = false;
            OnPropertyChanged(nameof(ShowEmpty));
        }
    }

    public async Task OpenAsync(BrowserItemViewModel? item)
    {
        if (item is null || _source is null) return;
        if (!item.IsFolder) { await PlayAsync(item); return; }
        _back.Push(_currentUri);
        CurrentFolderName = item.Name;
        await ShowFolderAsync(item.Item.Uri);
        CurrentFolderName = item.Name;
    }

    [RelayCommand]
    private async Task GoUp()
    {
        if (_back.Count > 0)
        {
            var uri = _back.Pop();
            await ShowFolderAsync(uri.Length == 0 ? null : uri);
        }
        else if (IsLocal && SourceUris.TryGetLocalPath(_currentUri, out var lp) && Path.GetDirectoryName(lp.TrimEnd('\\')) is { } parent)
        {
            await ShowFolderAsync(SourceUris.FromLocalPath(parent));
        }
        CurrentFolderName = FolderNameOf(_currentUri);
    }

    private string FolderNameOf(string uri)
    {
        if (uri.Length == 0) return Title;
        if (SourceUris.TryGetLocalPath(uri, out var p))
            return Path.GetFileName(p.TrimEnd('\\')) ?? p;
        var trimmed = uri.TrimEnd('/');
        var idx = trimmed.LastIndexOf('/');
        return idx >= 0 ? Uri.UnescapeDataString(trimmed[(idx + 1)..]) : uri;
    }

    [RelayCommand]
    private async Task Refresh() => await ShowFolderAsync(_currentUri.Length == 0 ? null : _currentUri);

    // ---- playback ----

    private async Task<Track?> ResolveTrackAsync(BrowserItemViewModel item)
    {
        if (item.Item.Track is { } t) return t;
        return _source is null ? null : await _source.GetTrackAsync(item.Item.Uri);
    }

    public async Task PlayAsync(BrowserItemViewModel? item)
    {
        if (item is null) return;
        if (await ResolveTrackAsync(item) is { } track) await _playback.PlayAsync(new[] { track }, 0);
        else _notifications.Warning("Cannot play", "Not a playable audio file.");
    }

    [RelayCommand]
    private async Task PlayFolder()
    {
        var tracks = new List<Track>();
        foreach (var item in Items.Where(i => i.IsPlayable))
            if (await ResolveTrackAsync(item) is { } t) tracks.Add(t);
        if (tracks.Count == 0) { _notifications.Warning("Nothing to play", "No audio files in this folder."); return; }
        await _playback.PlayAsync(tracks, 0);
    }

    [RelayCommand]
    private async Task EnqueueFolder(bool next)
    {
        var tracks = new List<Track>();
        foreach (var item in Items.Where(i => i.IsPlayable))
            if (await ResolveTrackAsync(item) is { } t) tracks.Add(t);
        if (tracks.Count == 0) return;
        if (next) _playback.EnqueueNext(tracks); else _playback.EnqueueLast(tracks);
    }

    // ---- file operations ----

    [RelayCommand]
    private async Task NewFolder()
    {
        if (_source is null || !Caps.HasFlag(SourceCapabilities.CreateFolder)) return;
        var name = await _dialogs.PromptAsync("New folder", "Folder name:");
        if (string.IsNullOrWhiteSpace(name)) return;
        try
        {
            await _source.CreateFolderAsync(_currentUri, name.Trim());
            await Refresh();
        }
        catch (Exception ex) { _notifications.Error("Cannot create folder", ex.Message); }
    }

    public async Task RenameAsync(BrowserItemViewModel? item)
    {
        if (item is null || _source is null || !Caps.HasFlag(SourceCapabilities.Rename)) return;
        var name = await _dialogs.PromptAsync("Rename", "New name:", item.Name);
        if (string.IsNullOrWhiteSpace(name) || name.Trim() == item.Name) return;
        try
        {
            await _source.RenameAsync(item.Item.Uri, name.Trim());
            await Refresh();
        }
        catch (Exception ex) { _notifications.Error("Cannot rename", ex.Message); }
    }

    public async Task DeleteAsync(IReadOnlyList<BrowserItemViewModel> selection)
    {
        if (_source is null || selection.Count == 0 || !Caps.HasFlag(SourceCapabilities.Delete)) return;
        var message = selection.Count == 1
            ? $"Delete \\u201C{selection[0].Name}\\u201D{(selection[0].IsFolder ? " and everything inside it" : "")}?"
            : $"Delete {selection.Count} items?";
        if (!await _dialogs.ConfirmAsync("Delete", message, "Delete")) return;
        foreach (var item in selection)
        {
            try { await _source.DeleteAsync(item.Item.Uri); }
            catch (Exception ex) { _notifications.Error($"Cannot delete {item.Name}", ex.Message); }
        }
        await Refresh();
    }

    [RelayCommand]
    private async Task UploadFiles()
    {
        if (_source is null || !Caps.HasFlag(SourceCapabilities.Upload)) return;
        var paths = await _dialogs.PickOpenFilesAsync("Upload", "*");
        foreach (var path in paths)
        {
            try
            {
                var info = new FileInfo(path);
                await using var stream = File.OpenRead(path);
                await _source.UploadAsync(_currentUri, info.Name, stream, info.Length);
                _notifications.Success("Uploaded", info.Name);
            }
            catch (Exception ex) { _notifications.Error($"Upload failed: {Path.GetFileName(path)}", ex.Message); }
        }
        await Refresh();
    }

    public async Task ExportAsync(IReadOnlyList<BrowserItemViewModel> selection)
    {
        if (selection.Count == 0) return;
        var folder = await _dialogs.PickFolderAsync("Export here");
        if (folder is null) return;
        foreach (var item in selection.Where(i => !i.IsFolder))
        {
            await _downloads.DownloadUriAsync(item.Item.Uri, item.Name, folder);
        }
        _notifications.Success("Export queued", $"{selection.Count} item{(selection.Count == 1 ? "" : "s")} \u2192 Downloads");
    }

    /// <summary>Move/copy within the local filesystem (or download+upload+delete for writable remote sources).</summary>
    public async Task MoveOrCopyAsync(IReadOnlyList<BrowserItemViewModel> selection, bool move)
    {
        if (_source is null || selection.Count == 0) return;
        if (IsLocal)
        {
            var folder = await _dialogs.PickFolderAsync(move ? "Move here" : "Copy here");
            if (folder is null) return;
            foreach (var item in selection)
            {
                if (!SourceUris.TryGetLocalPath(item.Item.Uri, out var src)) continue;
                try
                {
                    var dest = Path.Combine(folder, item.Name);
                    if (item.IsFolder)
                    {
                        if (move) Directory.Move(src, dest); else CopyDirectory(src, dest);
                    }
                    else
                    {
                        if (move) File.Move(src, dest, overwrite: false); else File.Copy(src, dest, overwrite: false);
                    }
                }
                catch (Exception ex) { _notifications.Error($"{(move ? "Move" : "Copy")} failed: {item.Name}", ex.Message); }
            }
            await Refresh();
            return;
        }

        // Remote: download to a temp file, upload into the chosen subfolder, then delete when moving.
        if (!Caps.HasFlag(SourceCapabilities.Upload)) return;
        var folders = Items.Where(i => i.IsFolder).ToList();
        if (folders.Count == 0)
        {
            _notifications.Warning("No subfolders", "Create a folder here first, then move into it.");
            return;
        }
        var names = string.Join(", ", folders.Select(f => f.Name));
        var targetName = await _dialogs.PromptAsync(move ? "Move to subfolder" : "Copy to subfolder", $"One of: {names}");
        var target = folders.FirstOrDefault(f => string.Equals(f.Name, targetName?.Trim(), StringComparison.OrdinalIgnoreCase));
        if (target is null) return;
        foreach (var item in selection.Where(i => !i.IsFolder))
        {
            try
            {
                var dl = await _downloads.DownloadUriAsync(item.Item.Uri, item.Name);
                // Wait for the temp download, then stream it back up.
                var file = await WaitForDownloadAsync(dl.Id);
                if (file is null) continue;
                var info = new FileInfo(file);
                await using (var stream = File.OpenRead(file))
                    await _source.UploadAsync(target.Item.Uri, item.Name, stream, info.Length);
                if (move) await _source.DeleteAsync(item.Item.Uri);
            }
            catch (Exception ex) { _notifications.Error($"{(move ? "Move" : "Copy")} failed: {item.Name}", ex.Message); }
        }
        await Refresh();
    }

    private async Task<string?> WaitForDownloadAsync(Guid downloadId)
    {
        var tcs = new TaskCompletionSource<string?>();
        void Handler(object? _, DownloadItem item)
        {
            if (item.Id != downloadId) return;
            if (item.State == DownloadState.Completed) tcs.TrySetResult(item.DestinationPath);
            else if (item.State is DownloadState.Failed or DownloadState.Canceled) tcs.TrySetResult(null);
        }
        _downloads.ItemChanged += Handler;
        try
        {
            var existing = _downloads.Items.FirstOrDefault(i => i.Id == downloadId);
            if (existing?.State == DownloadState.Completed) return existing.DestinationPath;
            return await Task.WhenAny(tcs.Task, Task.Delay(TimeSpan.FromMinutes(10))) == tcs.Task ? await tcs.Task : null;
        }
        finally
        {
            _downloads.ItemChanged -= Handler;
        }
    }

    private static void CopyDirectory(string source, string dest)
    {
        Directory.CreateDirectory(dest);
        foreach (var file in Directory.EnumerateFiles(source))
            File.Copy(file, Path.Combine(dest, Path.GetFileName(file)), overwrite: false);
        foreach (var dir in Directory.EnumerateDirectories(source))
            CopyDirectory(dir, Path.Combine(dest, Path.GetFileName(dir)));
    }

    [RelayCommand]
    private async Task AddFolderToLibrary()
    {
        if (!IsLocal || !SourceUris.TryGetLocalPath(_currentUri, out var path)) return;
        var scanner = Microsoft.Extensions.DependencyInjection.ServiceProviderServiceExtensions
            .GetRequiredService<MuurMusic.Core.Library.ILibraryScanner>(App.Services);
        await scanner.AddFolderAsync(path);
        _notifications.Success("Folder added", $"{path} is now in your library.");
    }
}
