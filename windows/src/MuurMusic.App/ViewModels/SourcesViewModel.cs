using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Dispatching;
using MuurMusic.App.Services;
using MuurMusic.Core.Discovery;
using MuurMusic.Core.Models;
using MuurMusic.Core.Sources;

namespace MuurMusic.App.ViewModels;

public enum SourceFieldKind { Text, Password, Number, Toggle, Choice, FilePath }

/// <summary>Declarative editor field for a source kind (drives the add/edit dialog).</summary>
public sealed record SourceFieldSpec(
    string Key, string Label, SourceFieldKind Kind, string? SecretKey = null,
    string Placeholder = "", string? Default = null, IReadOnlyList<string>? Choices = null);

public sealed record SourceCatalogEntry(SourceKind Kind, string Label, string Glyph, string Group);

public sealed partial class SourceItemViewModel : ObservableObject
{
    private readonly SourcesViewModel _parent;

    public SourceItemViewModel(IMusicSource source, SourcesViewModel parent)
    {
        Source = source;
        _parent = parent;
        _enabled = source.Config.Enabled;
    }

    public IMusicSource Source { get; }
    public Guid Id => Source.Config.Id;
    public string Name => Source.Config.Name;
    public SourceKind Kind => Source.Config.Kind;
    public string KindLabel => SourceCatalog.LabelFor(Source.Config.Kind);

    public string Subtitle => Source.Config.Kind switch
    {
        SourceKind.Smb or SourceKind.Ftp or SourceKind.Sftp =>
            Source.Config.Get(SourceKeys.Host) ?? Source.RootUri,
        SourceKind.WebDav => Source.Config.Get(SourceKeys.BaseUrl) ?? Source.Config.Get(SourceKeys.Host) ?? Source.RootUri,
        SourceKind.S3 => Source.Config.Get(SourceKeys.Bucket) ?? Source.RootUri,
        SourceKind.Subsonic or SourceKind.Jellyfin or SourceKind.Emby or SourceKind.Plex =>
            Source.Config.Get(SourceKeys.ServerUrl) ?? Source.RootUri,
        SourceKind.Zip => Source.Config.Get(SourceKeys.ArchiveUri) ?? Source.RootUri,
        _ => Source.RootUri,
    };

    [ObservableProperty] private bool _enabled;
    [ObservableProperty] private bool _isBusy;
    [ObservableProperty] private string _status = "";

    partial void OnEnabledChanged(bool value) => _parent.SetEnabled(this, value);

    [RelayCommand] private async Task Browse() => await _parent.BrowseAsync(this);
    [RelayCommand] private async Task Test() => await _parent.TestExistingAsync(this);
    [RelayCommand] private async Task Edit() => await _parent.EditAsync(this);
    [RelayCommand] private async Task Remove() => await _parent.RemoveWithConfirmAsync(this);
}

public sealed partial class DiscoveredItem
{
    private readonly SourcesViewModel _parent;

    public DiscoveredItem(DiscoveredServer server, SourcesViewModel parent)
    {
        Server = server;
        _parent = parent;
    }

    public DiscoveredServer Server { get; }
    public string Name => Server.Name;
    public string Subtitle => $"{Server.Kind} \u00B7 {Server.Host}:{Server.Port}";

    [RelayCommand] private async Task Add() => await _parent.AddDiscoveredAsync(this);
}

public sealed partial class DriveItem
{
    private readonly SourcesViewModel _parent;

    public DriveItem(string name, string root, string subtitle, SourcesViewModel parent)
    {
        Name = name;
        Root = root;
        Subtitle = subtitle;
        _parent = parent;
    }

    public string Name { get; }
    public string Root { get; }
    public string Subtitle { get; }

    [RelayCommand] private async Task Browse() => await _parent.BrowseDriveAsync(this);
    [RelayCommand] private async Task AddToLibrary() => await _parent.AddDriveToLibraryAsync(this);
}

/// <summary>Sources list, discovery scan, removable drives. Dialogs are hosted by the page via callbacks.</summary>
public sealed partial class SourcesViewModel : ObservableObject
{
    private readonly ISourceManager _sources;
    private readonly INetworkDiscovery _discovery;
    private readonly NotificationService _notifications;
    private CancellationTokenSource? _scanCts;

    public SourcesViewModel(ISourceManager sources, INetworkDiscovery discovery, NotificationService notifications)
    {
        _sources = sources;
        _discovery = discovery;
        _notifications = notifications;
        _sources.SourcesChanged += (_, _) => DispatcherQueue.GetForCurrentThread().TryEnqueue(Reload);
        _sources.RemovableDrives.DrivesChanged += (_, _) => DispatcherQueue.GetForCurrentThread().TryEnqueue(ReloadDrives);
        Reload();
        ReloadDrives();
    }

    // Page-hosted interactions (dialogs / navigation), assigned by SourcesPage.
    public Func<SourceItemViewModel, Task>? OnBrowse { get; set; }
    public Func<SourceItemViewModel, Task>? OnEdit { get; set; }
    public Func<DiscoveredItem, Task>? OnAddDiscovered { get; set; }
    public Func<DriveItem, Task>? OnBrowseDrive { get; set; }
    public Func<DriveItem, Task>? OnAddDriveToLibrary { get; set; }
    public Func<SourceItemViewModel, Task<bool>>? OnConfirmRemove { get; set; }

    public ObservableCollection<SourceItemViewModel> Sources { get; } = new();
    public ObservableCollection<DiscoveredItem> Discovered { get; } = new();
    public ObservableCollection<DriveItem> Drives { get; } = new();

    [ObservableProperty] private bool _isScanning;
    [ObservableProperty] private string _scanStatus = "";
    [ObservableProperty] private bool _hasSources;
    [ObservableProperty] private bool _hasDrives;

    public string ScanButtonText => IsScanning ? "Stop scan" : "Scan network";

    partial void OnIsScanningChanged(bool value) => OnPropertyChanged(nameof(ScanButtonText));

    internal void SetEnabled(SourceItemViewModel item, bool value)
    {
        if (item.Source.Config.Enabled == value) return;
        item.Source.Config.Enabled = value;
        _ = _sources.UpdateAsync(item.Source.Config);
    }

    internal async Task BrowseAsync(SourceItemViewModel item)
    {
        if (OnBrowse is not null) await OnBrowse(item);
    }

    internal async Task EditAsync(SourceItemViewModel item)
    {
        if (OnEdit is not null) await OnEdit(item);
    }

    internal async Task AddDiscoveredAsync(DiscoveredItem item)
    {
        if (OnAddDiscovered is not null) await OnAddDiscovered(item);
    }

    internal async Task BrowseDriveAsync(DriveItem item)
    {
        if (OnBrowseDrive is not null) await OnBrowseDrive(item);
    }

    internal async Task AddDriveToLibraryAsync(DriveItem item)
    {
        if (OnAddDriveToLibrary is not null) await OnAddDriveToLibrary(item);
    }

    internal async Task RemoveWithConfirmAsync(SourceItemViewModel item)
    {
        if (OnConfirmRemove is not null && !await OnConfirmRemove(item)) return;
        await RemoveAsync(item);
    }

    private void Reload()
    {
        Sources.Clear();
        foreach (var s in _sources.Sources)
            Sources.Add(new SourceItemViewModel(s, this));
        HasSources = Sources.Count > 0;
    }

    private void ReloadDrives()
    {
        Drives.Clear();
        foreach (var d in RemovableDrives.GetReadyDrives())
        {
            if (d.DriveType is not (DriveType.Removable or DriveType.CDRom)) continue;
            var label = string.IsNullOrWhiteSpace(d.VolumeLabel) ? d.Name.TrimEnd('\\') : $"{d.VolumeLabel} ({d.Name.TrimEnd('\\')})";
            Drives.Add(new DriveItem(label, d.RootDirectory.FullName, d.DriveType == DriveType.Removable ? "USB drive" : d.DriveType.ToString(), this));
        }
        HasDrives = Drives.Count > 0;
    }

    [RelayCommand]
    private async Task ScanNetwork()
    {
        if (IsScanning) { _scanCts?.Cancel(); return; }
        IsScanning = true;
        ScanStatus = "Looking for servers on your network\u2026";
        Discovered.Clear();
        _scanCts = new CancellationTokenSource();
        try
        {
            var found = await _discovery.ScanAsync(TimeSpan.FromSeconds(5), server =>
                DispatcherQueue.GetForCurrentThread().TryEnqueue(() =>
                {
                    if (Discovered.All(d => d.Server.Id != server.Id)) Discovered.Add(new DiscoveredItem(server, this));
                }), _scanCts.Token);
            ScanStatus = found.Count == 0
                ? "Nothing found this time. Make sure the server is on the same network, then try again."
                : $"Found {found.Count} server{(found.Count == 1 ? "" : "s")}.";
        }
        catch (OperationCanceledException)
        {
            ScanStatus = "Scan stopped.";
        }
        finally
        {
            IsScanning = false;
        }
    }

    public async Task<IMusicSource?> AddAsync(SourceConfig config, IReadOnlyDictionary<string, string?>? secrets, bool test = true)
    {
        try
        {
            var added = await _sources.AddAsync(config, secrets, test);
            _notifications.Success("Source added", config.Name);
            return added;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            _notifications.Error("Could not add source", ex.Message);
            return null;
        }
    }

    public async Task UpdateAsync(SourceConfig config, IReadOnlyDictionary<string, string?>? secrets)
    {
        await _sources.UpdateAsync(config, secrets);
        _notifications.Success("Source updated", config.Name);
    }

    public async Task RemoveAsync(SourceItemViewModel? item)
    {
        if (item is null) return;
        await _sources.RemoveAsync(item.Id);
        _notifications.Success("Source removed", item.Name);
    }

    public async Task TestExistingAsync(SourceItemViewModel? item)
    {
        if (item is null) return;
        item.IsBusy = true;
        item.Status = "Testing\u2026";
        try
        {
            await item.Source.TestConnectionAsync();
            item.Status = "Connected";
        }
        catch (Exception ex)
        {
            item.Status = "Failed";
            _notifications.Error($"{item.Name}: connection failed", ex.Message);
        }
        finally
        {
            item.IsBusy = false;
        }
    }
}

/// <summary>Labels, glyphs and editor field specs per source kind.</summary>
public static class SourceCatalog
{
    public static readonly IReadOnlyList<SourceCatalogEntry> Entries = new[]
    {
        new SourceCatalogEntry(SourceKind.Smb, "Windows / SMB share", "\uE8B7", "Servers & network"),
        new SourceCatalogEntry(SourceKind.WebDav, "WebDAV", "\uE753", "Servers & network"),
        new SourceCatalogEntry(SourceKind.Ftp, "FTP / FTPS", "\uE753", "Servers & network"),
        new SourceCatalogEntry(SourceKind.Sftp, "SFTP (SSH)", "\uE72E", "Servers & network"),
        new SourceCatalogEntry(SourceKind.Upnp, "DLNA / UPnP", "\uE968", "Servers & network"),
        new SourceCatalogEntry(SourceKind.S3, "S3 bucket", "\uE753", "Servers & network"),
        new SourceCatalogEntry(SourceKind.Subsonic, "Subsonic / Navidrome", "\uE8D6", "Media servers"),
        new SourceCatalogEntry(SourceKind.Jellyfin, "Jellyfin", "\uE8D6", "Media servers"),
        new SourceCatalogEntry(SourceKind.Emby, "Emby", "\uE8D6", "Media servers"),
        new SourceCatalogEntry(SourceKind.Plex, "Plex", "\uE8D6", "Media servers"),
        new SourceCatalogEntry(SourceKind.Dropbox, "Dropbox", "\uE753", "Cloud"),
        new SourceCatalogEntry(SourceKind.GoogleDrive, "Google Drive", "\uE753", "Cloud"),
        new SourceCatalogEntry(SourceKind.OneDrive, "OneDrive", "\uE753", "Cloud"),
        new SourceCatalogEntry(SourceKind.Box, "Box", "\uE753", "Cloud"),
        new SourceCatalogEntry(SourceKind.PCloud, "pCloud", "\uE753", "Cloud"),
        new SourceCatalogEntry(SourceKind.Zip, "Music archive (.zip)", "\uE7B8", "On this device"),
    };

    public static string LabelFor(SourceKind kind) =>
        Entries.FirstOrDefault(e => e.Kind == kind)?.Label ?? kind.ToString();

    public static bool IsOAuth(SourceKind kind) => kind is SourceKind.Dropbox or SourceKind.GoogleDrive or SourceKind.OneDrive or SourceKind.Box or SourceKind.PCloud;

    public static IReadOnlyList<SourceFieldSpec> FieldsFor(SourceKind kind) => kind switch
    {
        SourceKind.Smb => new SourceFieldSpec[]
        {
            new(SourceKeys.Host, "Server name or IP", SourceFieldKind.Text, Placeholder: "192.168.1.10 or NAS"),
            new(SourceKeys.Share, "Share name", SourceFieldKind.Text, Placeholder: "Music"),
            new(SourceKeys.Path, "Folder inside the share (optional)", SourceFieldKind.Text, Placeholder: "flac/lossless"),
            new(SourceKeys.Domain, "Domain (optional)", SourceFieldKind.Text),
            new(SourceKeys.Username, "Username", SourceFieldKind.Text),
            new(SourceKeys.Host + "-pw", "Password", SourceFieldKind.Password, SecretKey: SourceKeys.SecretPassword),
        },
        SourceKind.WebDav => new SourceFieldSpec[]
        {
            new(SourceKeys.Preset, "Service", SourceFieldKind.Choice, Default: "custom", Choices: WebDavPresets.All.Select(p => p.Id).ToList()),
            new(SourceKeys.Host, "Host or full URL", SourceFieldKind.Text, Placeholder: "cloud.example.com or https://\u2026/dav"),
            new(SourceKeys.Username, "Username", SourceFieldKind.Text),
            new(SourceKeys.Host + "-pw", "Password / app password", SourceFieldKind.Password, SecretKey: SourceKeys.SecretPassword),
            new(SourceKeys.AcceptAnyCertificate, "Accept self-signed certificates", SourceFieldKind.Toggle),
        },
        SourceKind.Ftp => new SourceFieldSpec[]
        {
            new(SourceKeys.Host, "Server", SourceFieldKind.Text),
            new(SourceKeys.Port, "Port", SourceFieldKind.Number, Default: "21"),
            new(SourceKeys.Path, "Start folder (optional)", SourceFieldKind.Text),
            new(SourceKeys.Username, "Username", SourceFieldKind.Text),
            new(SourceKeys.Host + "-pw", "Password", SourceFieldKind.Password, SecretKey: SourceKeys.SecretPassword),
            new(SourceKeys.UseTls, "Use TLS (FTPS)", SourceFieldKind.Toggle, Default: "true"),
            new(SourceKeys.ImplicitTls, "Implicit TLS (port 990)", SourceFieldKind.Toggle),
            new(SourceKeys.AcceptAnyCertificate, "Accept self-signed certificates", SourceFieldKind.Toggle),
        },
        SourceKind.Sftp => new SourceFieldSpec[]
        {
            new(SourceKeys.Host, "Server", SourceFieldKind.Text),
            new(SourceKeys.Port, "Port", SourceFieldKind.Number, Default: "22"),
            new(SourceKeys.Path, "Start folder (optional)", SourceFieldKind.Text),
            new(SourceKeys.Username, "Username", SourceFieldKind.Text),
            new(SourceKeys.Host + "-pw", "Password (optional)", SourceFieldKind.Password, SecretKey: SourceKeys.SecretPassword),
            new(SourceKeys.SecretPrivateKey, "Private key file (optional)", SourceFieldKind.FilePath, SecretKey: SourceKeys.SecretPrivateKey),
            new(SourceKeys.SecretPassphrase, "Key passphrase (optional)", SourceFieldKind.Password, SecretKey: SourceKeys.SecretPassphrase),
        },
        SourceKind.S3 => new SourceFieldSpec[]
        {
            new(SourceKeys.Endpoint, "Endpoint", SourceFieldKind.Text, Placeholder: "s3.amazonaws.com or minio:9000"),
            new(SourceKeys.Region, "Region", SourceFieldKind.Text, Placeholder: "us-east-1"),
            new(SourceKeys.Bucket, "Bucket", SourceFieldKind.Text),
            new(SourceKeys.Path, "Prefix (optional)", SourceFieldKind.Text),
            new(SourceKeys.SecretAccessKey, "Access key ID", SourceFieldKind.Text, SecretKey: SourceKeys.SecretAccessKey),
            new(SourceKeys.SecretSecretKey, "Secret access key", SourceFieldKind.Password, SecretKey: SourceKeys.SecretSecretKey),
            new(SourceKeys.PathStyle, "Path-style URLs (MinIO etc.)", SourceFieldKind.Toggle, Default: "true"),
        },
        SourceKind.Subsonic => new SourceFieldSpec[]
        {
            new(SourceKeys.ServerUrl, "Server URL", SourceFieldKind.Text, Placeholder: "https://music.example.com"),
            new(SourceKeys.Username, "Username", SourceFieldKind.Text),
            new(SourceKeys.Host + "-pw", "Password", SourceFieldKind.Password, SecretKey: SourceKeys.SecretPassword),
            new(SourceKeys.LegacyAuth, "Legacy (pre-API-1.13) auth", SourceFieldKind.Toggle),
        },
        SourceKind.Jellyfin or SourceKind.Emby => new SourceFieldSpec[]
        {
            new(SourceKeys.ServerUrl, "Server URL", SourceFieldKind.Text, Placeholder: "http://server:8096"),
            new(SourceKeys.Username, "Username", SourceFieldKind.Text),
            new(SourceKeys.Host + "-pw", "Password", SourceFieldKind.Password, SecretKey: SourceKeys.SecretPassword),
        },
        SourceKind.Upnp => new SourceFieldSpec[]
        {
            new(SourceKeys.DeviceLocation, "Device description URL", SourceFieldKind.Text, Placeholder: "http://192.168.1.20:1900/description.xml"),
        },
        SourceKind.Zip => new SourceFieldSpec[]
        {
            new(SourceKeys.ArchiveUri, "Archive file", SourceFieldKind.FilePath, Placeholder: "Pick a .zip of music"),
        },
        _ => Array.Empty<SourceFieldSpec>(),
    };
}
