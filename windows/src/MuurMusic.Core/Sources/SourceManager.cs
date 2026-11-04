using System.Collections.Concurrent;
using Microsoft.Extensions.Logging;
using MuurMusic.Core.Data;
using MuurMusic.Core.Models;
using MuurMusic.Core.Security;
using MuurMusic.Core.Settings;

namespace MuurMusic.Core.Sources;

/// <summary>Owns all configured sources, creates source instances and resolves playable locations for tracks.</summary>
public interface ISourceManager : ISourceResolver
{
    /// <summary>Loads persisted sources. Call once at startup.</summary>
    Task InitializeAsync(CancellationToken ct = default);
    /// <summary>All sources: the built-in local source first, then configured sources in sort order.</summary>
    IReadOnlyList<IMusicSource> Sources { get; }
    /// <summary>Built-in source for local disks and removable drives (not persisted).</summary>
    IMusicSource LocalSource { get; }
    /// <summary>Removable drive monitor; its event fires when USB drives come and go.</summary>
    RemovableDrives RemovableDrives { get; }
    /// <summary>Raised (on a background thread) when sources are added, updated or removed.</summary>
    event EventHandler? SourcesChanged;
    /// <summary>Creates an unsaved instance, e.g. to test a connection before saving.</summary>
    IMusicSource Create(SourceConfig config);
    /// <summary>Stores secrets, optionally tests the connection, then persists the source.</summary>
    Task<IMusicSource> AddAsync(SourceConfig config, IReadOnlyDictionary<string, string?>? secrets = null, bool testConnection = true, CancellationToken ct = default);
    Task<IMusicSource> UpdateAsync(SourceConfig config, IReadOnlyDictionary<string, string?>? secrets = null, CancellationToken ct = default);
    Task RemoveAsync(Guid id, CancellationToken ct = default);
    /// <summary>Stores secrets for a source id (null values remove the secret).</summary>
    Task SetSecretsAsync(Guid sourceId, IReadOnlyDictionary<string, string?> secrets, CancellationToken ct = default);
    IMusicSource? Get(Guid id);
    /// <summary>Finds the source owning a URI (creates a transient ZIP source for zip:// URIs).</summary>
    IMusicSource? FindForUri(string uri);
    /// <summary>Resolves a track honoring offline copies, the audio cache and offline mode.</summary>
    Task<MediaLocation> ResolveTrackAsync(Track track, CancellationToken ct = default);
    Task<Track?> GetTrackAsync(string uri, CancellationToken ct = default);
}

public sealed class SourceManager : ISourceManager, IAsyncDisposable
{
    public static readonly Guid LocalSourceId = new("00000000-0000-0000-0000-000000000001");

    private readonly ISourceRepository _repo;
    private readonly ICredentialStore _credentials;
    private readonly SourceContext _ctx;
    private readonly ISettingsService _settings;
    private readonly IAudioCacheRepository _cache;
    private readonly ILogger<SourceManager> _log;
    private readonly ConcurrentDictionary<Guid, IMusicSource> _sources = new();
    private readonly ConcurrentDictionary<string, ZipSource> _zips = new(StringComparer.OrdinalIgnoreCase);
    private List<IMusicSource> _ordered = new();

    public SourceManager(ISourceRepository repo, ICredentialStore credentials, SourceContext ctx, ISettingsService settings, IAudioCacheRepository cache, ILogger<SourceManager> log)
    {
        _repo = repo;
        _credentials = credentials;
        _ctx = ctx;
        _settings = settings;
        _cache = cache;
        _log = log;
        LocalSource = new LocalSource(new SourceConfig { Id = LocalSourceId, Kind = SourceKind.Local, Name = "This PC" }, settings);
        RemovableDrives = new RemovableDrives();
        RemovableDrives.DrivesChanged += (_, _) => SourcesChanged?.Invoke(this, EventArgs.Empty);
        _ordered = new List<IMusicSource> { LocalSource };
    }

    public IMusicSource LocalSource { get; }
    public RemovableDrives RemovableDrives { get; }
    public IReadOnlyList<IMusicSource> Sources => _ordered;
    public event EventHandler? SourcesChanged;

    public async Task InitializeAsync(CancellationToken ct = default)
    {
        foreach (var cfg in await _repo.GetAllAsync(ct).ConfigureAwait(false))
        {
            try { _sources[cfg.Id] = Create(cfg); }
            catch (SourceException ex) { _log.LogWarning(ex, "Source {Name} could not be created", cfg.Name); }
        }
        Reorder();
    }

    private void Reorder()
    {
        _ordered = new[] { LocalSource }.Concat(_sources.Values.OrderBy(s => s.Config.SortOrder).ThenBy(s => s.Config.Name, StringComparer.CurrentCultureIgnoreCase)).ToList();
        SourcesChanged?.Invoke(this, EventArgs.Empty);
    }

    public IMusicSource Create(SourceConfig config) => config.Kind switch
    {
        SourceKind.Local => new LocalSource(config, _settings),
        SourceKind.Smb => new SmbSource(config, _ctx),
        SourceKind.WebDav => new WebDavSource(config, _ctx),
        SourceKind.Ftp => new FtpSource(config, _ctx),
        SourceKind.Sftp => new SftpSource(config, _ctx),
        SourceKind.Upnp => new UpnpSource(config, _ctx),
        SourceKind.S3 => new S3Source(config, _ctx),
        SourceKind.Dropbox => new DropboxSource(config, _ctx),
        SourceKind.GoogleDrive => new GoogleDriveSource(config, _ctx),
        SourceKind.OneDrive => new OneDriveSource(config, _ctx),
        SourceKind.Box => new BoxSource(config, _ctx),
        SourceKind.PCloud => new PCloudSource(config, _ctx),
        SourceKind.Subsonic => new SubsonicSource(config, _ctx),
        SourceKind.Jellyfin or SourceKind.Emby => new JellyfinSource(config, _ctx),
        SourceKind.Plex => new PlexSource(config, _ctx),
        SourceKind.Zip => new ZipSource(config, _ctx, this),
        _ => throw new SourceException($"Unsupported source type {config.Kind}")
    };

    public async Task SetSecretsAsync(Guid sourceId, IReadOnlyDictionary<string, string?> secrets, CancellationToken ct = default)
    {
        foreach (var (name, value) in secrets)
            await _credentials.SetSourceSecretAsync(sourceId, name, value, ct).ConfigureAwait(false);
    }

    public async Task<IMusicSource> AddAsync(SourceConfig config, IReadOnlyDictionary<string, string?>? secrets = null, bool testConnection = true, CancellationToken ct = default)
    {
        if (secrets is not null) await SetSecretsAsync(config.Id, secrets, ct).ConfigureAwait(false);
        var source = Create(config);
        if (testConnection)
        {
            try { await source.TestConnectionAsync(ct).ConfigureAwait(false); }
            catch
            {
                if (secrets is not null) await _credentials.RemoveSourceSecretsAsync(config.Id, CancellationToken.None).ConfigureAwait(false);
                await source.DisposeAsync().ConfigureAwait(false);
                throw;
            }
        }
        if (config.SortOrder == 0) config.SortOrder = _sources.Count + 1;
        await _repo.SaveAsync(config, ct).ConfigureAwait(false);
        _sources[config.Id] = source;
        Reorder();
        return source;
    }

    public async Task<IMusicSource> UpdateAsync(SourceConfig config, IReadOnlyDictionary<string, string?>? secrets = null, CancellationToken ct = default)
    {
        if (secrets is not null) await SetSecretsAsync(config.Id, secrets, ct).ConfigureAwait(false);
        await _repo.SaveAsync(config, ct).ConfigureAwait(false);
        if (_sources.TryRemove(config.Id, out var old)) await old.DisposeAsync().ConfigureAwait(false);
        var source = Create(config);
        _sources[config.Id] = source;
        Reorder();
        return source;
    }

    public async Task RemoveAsync(Guid id, CancellationToken ct = default)
    {
        if (id == LocalSourceId) throw new InvalidOperationException("The local source cannot be removed.");
        await _repo.DeleteAsync(id, ct).ConfigureAwait(false);
        await _credentials.RemoveSourceSecretsAsync(id, ct).ConfigureAwait(false);
        if (_sources.TryRemove(id, out var old)) await old.DisposeAsync().ConfigureAwait(false);
        Reorder();
    }

    public IMusicSource? Get(Guid id) => id == LocalSourceId ? LocalSource : _sources.GetValueOrDefault(id);

    public IMusicSource? FindForUri(string uri)
    {
        if (SourceUris.TryParseSourceScoped(uri, out _, out var id, out _) && _sources.TryGetValue(id, out var scoped)) return scoped;
        if (SourceUris.TryParseZip(uri, out var archive, out _))
        {
            var configured = _sources.Values.FirstOrDefault(s => s.Kind == SourceKind.Zip && s.Owns(uri));
            if (configured is not null) return configured;
            return _zips.GetOrAdd(archive, a => new ZipSource(new SourceConfig { Kind = SourceKind.Zip, Name = SourceUris.FileNameOf(a) }.Set(SourceKeys.ArchiveUri, a), _ctx, this));
        }
        var match = _sources.Values.Where(s => s.Kind != SourceKind.Zip && s.Owns(uri)).OrderByDescending(s => s.RootUri.Length).FirstOrDefault();
        if (match is not null) return match;
        if (SourceUris.SchemeOf(uri) is SourceUris.File) return LocalSource;
        return null;
    }

    public async Task<MediaLocation> ResolveAsync(string uri, CancellationToken ct = default)
    {
        if (SourceUris.SchemeOf(uri) is SourceUris.Http or SourceUris.Https) return MediaLocation.ForUrl(uri);
        if (SourceUris.SchemeOf(uri) == SourceUris.Smb && FindForUri(uri) is SmbSource smb) return await smb.ResolveAsync(uri, ct).ConfigureAwait(false);
        if (SourceUris.TryGetLocalPath(uri, out var path) && File.Exists(path)) return MediaLocation.ForFile(path);
        var source = FindForUri(uri) ?? throw new SourceException($"No configured source can open {SourceUris.FileNameOf(uri)}.");
        if (_settings.Current.OfflineMode && source.Kind != SourceKind.Local && source.Kind != SourceKind.Zip) throw new OfflineException(uri);
        return await source.ResolveAsync(uri, ct).ConfigureAwait(false);
    }

    public async Task<MediaLocation> ResolveTrackAsync(Track track, CancellationToken ct = default)
    {
        if (!string.IsNullOrEmpty(track.LocalCopyPath) && File.Exists(track.LocalCopyPath)) return MediaLocation.ForFile(track.LocalCopyPath, cachedCopy: true);
        if (!string.IsNullOrEmpty(track.FilePath) && File.Exists(track.FilePath)) return MediaLocation.ForFile(track.FilePath);
        var scheme = SourceUris.SchemeOf(track.SourceUri);
        if (scheme is not SourceUris.File)
        {
            var cached = await _cache.GetAsync(track.SourceUri, ct).ConfigureAwait(false);
            if (cached is { } c && File.Exists(c.Path))
            {
                await _cache.TouchAsync(track.SourceUri, ct).ConfigureAwait(false);
                return MediaLocation.ForFile(c.Path, cachedCopy: true);
            }
            if (cached is not null) await _cache.DeleteAsync(track.SourceUri, ct).ConfigureAwait(false);
        }
        return await ResolveAsync(track.SourceUri, ct).ConfigureAwait(false);
    }

    public async Task<Track?> GetTrackAsync(string uri, CancellationToken ct = default)
    {
        var source = FindForUri(uri);
        return source is null ? null : await source.GetTrackAsync(uri, ct).ConfigureAwait(false);
    }

    public async ValueTask DisposeAsync()
    {
        RemovableDrives.Dispose();
        foreach (var s in _sources.Values) await s.DisposeAsync().ConfigureAwait(false);
        foreach (var z in _zips.Values) await z.DisposeAsync().ConfigureAwait(false);
        _sources.Clear();
    }
}
