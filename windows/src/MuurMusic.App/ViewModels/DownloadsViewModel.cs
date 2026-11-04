using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using Microsoft.Extensions.DependencyInjection;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Dispatching;
using MuurMusic.App.Services;
using MuurMusic.Core.Downloads;
using MuurMusic.Core.Models;
using MuurMusic.Core.Settings;

namespace MuurMusic.App.ViewModels;

public sealed partial class DownloadItemViewModel : ObservableObject
{
    public required DownloadItem Item { get; init; }

    public Guid Id => Item.Id;
    public string Title => Item.Title;
    public string Artist => Item.Artist ?? "";
    public double ProgressPercent => Item.Progress * 100;
    public string KindLabel => Item.Kind switch
    {
        DownloadKind.Offline => "Offline",
        DownloadKind.Cache => "Cache",
        _ => "Export",
    };

    public string StatusText => Item.State switch
    {
        DownloadState.Queued => "Queued",
        DownloadState.Downloading => $"{Services.Formatters.Bytes(Item.DownloadedBytes)} of {Services.Formatters.Bytes(Item.TotalBytes)}",
        DownloadState.Paused => "Paused",
        DownloadState.Completed => "Done",
        DownloadState.Failed => $"Failed: {Item.Error}",
        _ => "Canceled",
    };

    // Command proxies wired by the parent view model (DataTemplates can't x:Bind to it).
    public CommunityToolkit.Mvvm.Input.IRelayCommand<DownloadItemViewModel>? PauseCommandProxy { get; set; }
    public CommunityToolkit.Mvvm.Input.IRelayCommand<DownloadItemViewModel>? ResumeCommandProxy { get; set; }
    public CommunityToolkit.Mvvm.Input.IAsyncRelayCommand<DownloadItemViewModel>? CancelCommandProxy { get; set; }
    public CommunityToolkit.Mvvm.Input.IRelayCommand<DownloadItemViewModel>? RetryCommandProxy { get; set; }
    public CommunityToolkit.Mvvm.Input.IAsyncRelayCommand<DownloadItemViewModel>? RemoveCommandProxy { get; set; }

    public bool IsActive => Item.State is DownloadState.Queued or DownloadState.Downloading or DownloadState.Paused;
    public bool CanPause => Item.State is DownloadState.Queued or DownloadState.Downloading;
    public bool CanResume => Item.State == DownloadState.Paused;
    public bool CanRetry => Item.State is DownloadState.Failed or DownloadState.Canceled;
    public bool IsFinished => Item.State == DownloadState.Completed;
    public bool ShowProgress => Item.State is DownloadState.Downloading or DownloadState.Queued;
}

/// <summary>Downloads page: active queue, finished items, cache and offline storage stats.</summary>
public sealed partial class DownloadsViewModel : ObservableObject
{
    private readonly IDownloadManager _downloads;
    private readonly ISettingsService _settings;
    private readonly NotificationService _notifications;

    public DownloadsViewModel(IDownloadManager downloads, ISettingsService settings, NotificationService notifications)
    {
        _downloads = downloads;
        _settings = settings;
        _notifications = notifications;
        _downloads.ItemChanged += (_, item) => DispatcherQueue.GetForCurrentThread().TryEnqueue(() => OnItemChanged(item));
        _downloads.ItemsChanged += (_, _) => DispatcherQueue.GetForCurrentThread().TryEnqueue(Reload);
        _downloads.OfflineCopyChanged += (_, _) => DispatcherQueue.GetForCurrentThread().TryEnqueue(async () => await RefreshSizesAsync());
    }

    public ObservableCollection<DownloadItemViewModel> Active { get; } = new();
    public ObservableCollection<DownloadItemViewModel> Finished { get; } = new();

    [ObservableProperty] private string _cacheSizeText = "";
    [ObservableProperty] private string _offlineSizeText = "";
    [ObservableProperty] private string _cacheLimitText = "";
    [ObservableProperty] private double _cacheLimitGb = 2;
    [ObservableProperty] private string _downloadFolder = "";
    [ObservableProperty] private bool _hasActive;
    [ObservableProperty] private bool _hasFinished;
    public bool ShowEmpty => !HasActive && !HasFinished;
    partial void OnHasActiveChanged(bool value) => OnPropertyChanged(nameof(ShowEmpty));
    partial void OnHasFinishedChanged(bool value) => OnPropertyChanged(nameof(ShowEmpty));

    public async Task LoadAsync()
    {
        Reload();
        DownloadFolder = _settings.Current.DownloadFolder ?? "";
        CacheLimitGb = Math.Round(_settings.Current.AudioCacheMaxBytes / (1024.0 * 1024 * 1024), 1);
        await RefreshSizesAsync();
    }

    private void Reload()
    {
        var items = _downloads.Items.OrderByDescending(i => i.Created).ToList();
        Active.Clear();
        Finished.Clear();
        foreach (var item in items)
        {
            var vm = Wire(new DownloadItemViewModel { Item = item });
            if (item.State is DownloadState.Completed or DownloadState.Failed or DownloadState.Canceled) Finished.Add(vm);
            else Active.Add(vm);
        }
        HasActive = Active.Count > 0;
        HasFinished = Finished.Count > 0;
    }

    private void OnItemChanged(DownloadItem item)
    {
        var existing = Active.Concat(Finished).FirstOrDefault(v => v.Id == item.Id);
        if (existing is null) { Reload(); return; }
        // Rebind by replacing the row so all computed text updates.
        var vm = Wire(new DownloadItemViewModel { Item = item });
        var ai = Active.IndexOf(existing);
        if (ai >= 0) Active[ai] = vm;
        var fi = Finished.IndexOf(existing);
        if (fi >= 0) Finished[fi] = vm;
        if (item.State is DownloadState.Completed or DownloadState.Failed or DownloadState.Canceled && existing.IsActive) Reload();
        if (item.State == DownloadState.Completed) _notifications.Success("Download complete", item.Title);
        if (item.State == DownloadState.Failed) _notifications.Error("Download failed", $"{item.Title}: {item.Error}");
    }

    private DownloadItemViewModel Wire(DownloadItemViewModel vm)
    {
        vm.PauseCommandProxy = PauseCommand;
        vm.ResumeCommandProxy = ResumeCommand;
        vm.CancelCommandProxy = CancelCommand;
        vm.RetryCommandProxy = RetryCommand;
        vm.RemoveCommandProxy = RemoveCommand;
        return vm;
    }

    private async Task RefreshSizesAsync()
    {
        var cache = await _downloads.GetCacheSizeAsync();
        var offline = _downloads.GetOfflineSize();
        CacheSizeText = $"{Services.Formatters.Bytes(cache)} cached for smooth streaming";
        OfflineSizeText = $"{Services.Formatters.Bytes(offline)} kept for offline listening";
        var limit = _settings.Current.AudioCacheMaxBytes;
        CacheLimitText = $"Stream cache limit: {Services.Formatters.Bytes(limit)}";
    }

    [RelayCommand] private void Pause(DownloadItemViewModel? item) { if (item is not null) _downloads.Pause(item.Id); }
    [RelayCommand] private void Resume(DownloadItemViewModel? item) { if (item is not null) _downloads.Resume(item.Id); }
    [RelayCommand] private async Task Cancel(DownloadItemViewModel? item) { if (item is not null) await _downloads.CancelAsync(item.Id); }
    [RelayCommand] private void Retry(DownloadItemViewModel? item) { if (item is not null) _downloads.Retry(item.Id); }
    [RelayCommand] private async Task Remove(DownloadItemViewModel? item) { if (item is not null) await _downloads.RemoveAsync(item.Id, deleteFile: false); }

    [RelayCommand] private void PauseAll() => _downloads.PauseAll();
    [RelayCommand] private void ResumeAll() => _downloads.ResumeAll();

    [RelayCommand]
    private async Task ClearFinished()
    {
        await _downloads.ClearFinishedAsync();
        Reload();
    }

    [RelayCommand]
    private async Task ClearCache()
    {
        await _downloads.ClearCacheAsync();
        await RefreshSizesAsync();
        _notifications.Success("Cache cleared", "Streamed audio cache is empty again.");
    }

    [RelayCommand]
    private async Task ApplyCacheLimit()
    {
        var bytes = (long)(CacheLimitGb * 1024 * 1024 * 1024);
        _settings.Update(s => s.AudioCacheMaxBytes = bytes);
        await _downloads.EnforceCacheLimitAsync();
        await RefreshSizesAsync();
    }

    [RelayCommand]
    private void OpenDownloadFolder()
    {
        var folder = DownloadFolder;
        if (folder.Length > 0)
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe", $"\"{folder}\"") { UseShellExecute = true });
    }

    [RelayCommand]
    private async Task ChangeDownloadFolder()
    {
        var dialogs = App.Services.GetRequiredService<DialogService>();
        var folder = await dialogs.PickFolderAsync("Download here");
        if (folder is null) return;
        _settings.Update(s => s.DownloadFolder = folder);
        DownloadFolder = folder;
    }
}
