# MuurMusic Windows — Core & Audio API Guide

This document is the contract between the platform layer (Phase 1: `MuurMusic.Core` + `MuurMusic.Audio`)
and the WinUI 3 application (`MuurMusic.App`, Phase 2). It covers project layout, DI bootstrap, the
threading/event model, and every public service surface the UI needs.

Both libraries target `net10.0` (Core) and `net10.0-windows10.0.19041.0` (Audio). Everything is
`Microsoft.Extensions.*`-based (DI, logging, configuration, HTTP).

## Repository layout

```
windows/
  MuurMusic.sln
  Directory.Build.props          # shared TFM constants, NoWarn, win-x64
  Directory.Packages.props       # central package management (all versions pinned here)
  appsettings.json               # copied next to every output; OAuth client ids go here (see below)
  src/
    MuurMusic.Core/              # models, settings, SQLite, library scan, tags, lyrics, playlists,
                                 # smart playlists, sources (local/network/cloud/servers), OAuth,
                                 # downloads, queue persistence, network discovery. Zero UI, zero audio decode.
    MuurMusic.Audio/             # FFmpeg decoding, DSP, WASAPI output, playback engine, casting, SMTC.
    MuurMusic.App/               # (Phase 2 — does not exist yet)
  tests/
    MuurMusic.Core.Tests/        # xUnit; format parsers, SigV4, smart playlists, presets
    MuurMusic.Audio.Tests/       # xUnit; biquads, gapless/crossfade engine, WSOLA, FFmpeg decode smoke
docs/specs/                      # shared JSON format specs (authoritative, cross-platform)
```

## Bootstrap (what the App must do at startup)

```csharp
var services = new ServiceCollection();

services.AddMuurCore(options =>
{
    // All optional:
    // options.DataRoot = ...;              // default: %LOCALAPPDATA%\MuurMusic (env MUURMUSIC_DATA overrides)
    // options.ConfigurationDirectory = ...;// default: content root; where appsettings.json is read from
    // options.MinimumLogLevel = LogLevel.Information;
    // options.DebugLogging = true;         // enables ffmpeg + verbose logging
});

services.AddMuurAudio();                   // registers decode/output/cast/playback

var provider = services.BuildServiceProvider();

// Marshal all service events onto the UI thread (optional but recommended):
provider.GetRequiredService<IEventDispatcher>()
        .SetPoster(action => dispatcherQueue.TryEnqueue(() => action()));

await MuurCoreStartup.InitializeAsync(provider);   // DB migrate, sources, downloads, watchers, startup scan
await provider.GetRequiredService<IPlaybackService>()
        .InitializeAsync(mainWindowHandle);        // SMTC + queue restore (+ optional resume)
```

`IEventDispatcher` (`MuurMusic.Core.Infrastructure`) has exactly two members:
`void Post(Action)` and `void SetPoster(Action<Action>?)`. All `IPlaybackService`, `ISettingsService`,
`ILibraryScanner`, `IDownloadManager` and `ICastManager` events are raised **through** the dispatcher, so
setting a poster guarantees UI-thread delivery for everything except the low-level engine events
(`AudioEngine.*`, raised on an internal pump thread — you normally never touch the engine directly).

Dispose order: `await provider.GetRequiredService<IPlaybackService>().FlushAsync()` (persists queue/position),
then dispose the service provider.

## Threading model

- `IPlaybackService` serializes every operation on a single internal worker. All its public methods are
  safe to call from the UI thread; events come back through `IEventDispatcher`.
- Repositories and services are stateless/async; call from anywhere, `await` them.
- `PlayQueue` is **not** thread-safe; only mutate it through `IPlaybackService` methods
  (`EnqueueNext`, `EnqueueLast`, `RemoveFromQueueAsync`, `MoveQueueEntry`, `ClearQueueAsync`).
- `SpectrumAnalyzer`/`AudioMeter` (on `AudioEngine`, exposed via `IPlaybackService.Engine`) are
  thread-safe; poll them from a ~30-60 fps UI timer.

---

# Core layer (MuurMusic.Core)

## Settings — `ISettingsService` (MuurMusic.Core.Settings)

```csharp
AppSettings Current { get; }                                  // live snapshot (mutate only via Update)
event EventHandler<SettingsChangedEventArgs> Changed;         // { Old, New }
void Update(Action<AppSettings> mutate);                      // persists (debounced) + raises Changed
Task FlushAsync();
```

`AppSettings` properties (defaults in parentheses):

| Group | Members |
|---|---|
| UI | `Theme` (System), `Accent` ("Amber"), `NowPlayingStyle` ("Artwork"), `TabsOrder`, `VisualizerPreset` ("SpectrumBars"), `VisualizerAutoCycle` (false), `VisualizerAutoCycleSeconds` (30), `ShowToastOnTrackChange` (false), `MiniPlayerAlwaysOnTop` (true) |
| Output | `OutputDeviceId` (null = default), `ExclusiveMode` (false), `OutputSampleRate` (0 = follow source), `OutputBufferMs` (100) |
| Playback | `Gapless` (true), `CrossfadeSeconds` (0), `ReplayGain` (ReplayGainMode.Off), `ReplayGainPreampDb`, `ReplayGainUntaggedDb`, `ReplayGainClipPrevention` (true), `Volume` (0.8), `Muted` (false), `Speed` (1.0), `SkipBackSeconds` (10), `SkipForwardSeconds` (30), `RememberQueue` (true), `ResumePlaybackOnStartup` (false), `Shuffle`, `Repeat` |
| Decode | `HighQualityResampler` (true) |
| DSP | `EqEnabled`, `EqPresetName` ("Flat"), `EqPreampDb`, `EqBands` (double[10]), `DspChainEnabled`, `DspChainJson`, `LoudnessBoostEnabled`, `LoudnessBoostDb` (6) |
| Library | `WatchedFolders`, `ExcludedFolders`, `ScanOnStartup` (true), `WatchForChanges` (true), `MinTrackSeconds` (0), `ExpandCueSheets` (true) |
| Online | `FetchLyricsOnline` (true), `FetchArtworkOnline` (true), `OfflineMode` (false) |
| Downloads | `AudioCacheEnabled` (true), `AudioCacheMaxBytes` (2 GiB), `DownloadConcurrency` (3), `DownloadFolder`, `PrefetchNextTrack` (true), `StreamBufferSeconds` (15) |
| Casting | `LastCastDeviceId` |

`ReplayGainMode { Off, Track, Album }`, `ThemeMode { System, Dark, Light }`. The playback service already
applies every playback/DSP/output setting live on `Changed` — the UI only has to write settings, not push
them into the player.

## Track model (MuurMusic.Core.Models)

`Track`: `Id` (0 = not in DB), `SourceUri` (unique identity, e.g. `file:///...`, `smb://...`),
`SourceId`, `FilePath`, `Folder`, `FileName`, `CueStartMs`/`CueEndMs`/`CueSheetPath` (CUE sub-tracks),
`Title/Artist/Album/AlbumArtist/Genre/Composer/Comment` (nullable), `Year/TrackNumber/TrackTotal/
DiscNumber/DiscTotal/Bpm` (int?), `HasLyrics`, `Rating` (0-5), `PlayCount`, `SkipCount`, `LastPlayed`,
`DateAdded`, `Favorite`, `DurationMs`, `Bitrate` (kbps), `SampleRate`, `BitDepth`, `Channels`, `Codec`,
`Format`, `FileSize`, `FileModifiedMs`, `ArtworkHash`, `ReplayGainTrackGain/Peak`, `ReplayGainAlbumGain/Peak`
(double?), `IsRemote`, `LocalCopyPath` (offline copy), `MusicBrainzRecordingId/ReleaseId`,
`IsUnavailable`, `ArtworkUrl` (remote artwork).
Computed: `Duration`, `IsCueTrack`, `DisplayTitle`, `DisplayArtist`, `DisplayAlbum`,
`EffectiveAlbumArtist`, `IsLossless`, `IsHiRes`, `QualityBadge` (e.g. "FLAC 24/96"),
`Key` (SourceUri + CUE suffix — use as dictionary key), `Clone()`.

Aggregates: `Album(Key, Title, Artist, Year, TrackCount, DiscCount, DurationMs, MaxBitDepth,
MaxSampleRate, Codec, ArtworkHash, ...)` with `IsHiRes`; `Artist(Name, AlbumCount, TrackCount, DurationMs,
ArtworkHash)`; `Genre`, `Composer`, `LibraryFolder(Path, Name, TrackCount, HasSubfolders)`,
`FolderContents(Path, Folders, Tracks)`, `LibraryStats(...)`.

## Library queries — `ITrackRepository` (MuurMusic.Core.Data)

```csharp
Task<IReadOnlyList<Track>> QueryAsync(TrackQuery q, CancellationToken);
Task<int> CountAsync(TrackQuery q, ...);
Task<Track?> GetByIdAsync(long id);  GetByIdsAsync(IEnumerable<long>);
Task<Track?> GetBySourceUriAsync(string uri, long cueStartMs = 0);
Task<IReadOnlyList<Track>> GetByFilePathAsync(string path);

Task<IReadOnlyList<Album>> GetAlbumsAsync(AlbumQuery q);
Task<Album?> GetAlbumAsync(string albumKey);  GetAlbumTracksAsync(string albumKey);
Task<IReadOnlyList<Artist>> GetArtistsAsync(bool albumArtists, string? search = null, bool availableOnly = false);
Task<IReadOnlyList<Genre>> GetGenresAsync(bool availableOnly = false);
Task<IReadOnlyList<Composer>> GetComposersAsync(bool availableOnly = false);
Task<FolderContents> GetFolderContentsAsync(string folder, TrackSortField sort = FileName, bool availableOnly = false);
Task<IReadOnlyList<LibraryFolder>> GetRootFoldersAsync(IEnumerable<string> roots);
Task<LibraryStats> GetStatsAsync();

Task<IReadOnlyList<Track>> GetRecentlyPlayedAsync(int limit = 50, bool availableOnly = false);
GetRecentlyAddedAsync(...);  GetMostPlayedAsync(...);
GetFavoritesAsync(TrackSortField sort = Artist, bool availableOnly = false);
Task<IReadOnlyList<Track>> QuerySmartAsync(SmartPlaylistDefinition def, bool availableOnly = false);

Task SetRatingAsync(long id, int rating);  SetFavoriteAsync(long id, bool);
Task RecordPlayAsync(Track, long playedMs, bool completed);   // playback service already calls these
Task RecordSkipAsync(long id);
Task<IReadOnlyList<PlayHistoryEntry>> GetHistoryAsync(int limit = 200, int offset = 0);
Task ClearHistoryAsync();
// + upsert/delete/index methods used by the scanner — the UI rarely needs them.
```

`TrackQuery`: `Search` (FTS across title/artist/album), `Artist`, `AlbumArtist`, `AlbumKey`, `Genre`,
`Composer`, `Folder` + `IncludeSubfolders`, `FavoritesOnly`, `MinRating`, `SourceId`, `AvailableOnly`
(hides unavailable remote tracks), `Sort` (`TrackSortField`: Title, Artist, Album, AlbumArtist, Year,
DateAdded, LastPlayed, PlayCount, Rating, Duration, FileName, Random, ...), `Descending`, `Offset`,
`Limit` (0 = all). `AlbumQuery` is the analogous album-level shape (`AlbumSortField`).

## Library scanning — `ILibraryScanner` (MuurMusic.Core.Library)

```csharp
bool IsScanning { get; }
event EventHandler<ScanProgress> Progress;        // background thread (via dispatcher)
event EventHandler<ScanResult> ScanCompleted;
event EventHandler LibraryChanged;                // any library mutation — refresh browsers
Task<ScanResult> ScanAsync(IEnumerable<string>? folders = null, bool full = false, ...);
Task<ScanResult> ScanFilesAsync(IEnumerable<string> files, ...);   // after tag edits
Task<ScanResult> AddFolderAsync(string folder, ...);               // watch + scan
Task RemoveFolderAsync(string folder, ...);                        // unwatch + delete its tracks
void CancelScan();  void StartWatching();  void StopWatching();
```
`ScanProgress(Phase, FilesFound, FilesToRead, FilesRead, Added, Updated, Removed, CurrentPath)`.
Uses TagLib when possible, falls back to `IMediaProbe` (FFmpeg) for formats TagLib cannot read
(DSD, some AAC, etc.). Expands CUE sheets when `AppSettings.ExpandCueSheets` is on.

## Tags — `ITagService` (MuurMusic.Core.Tags)

```csharp
bool CanHandle(string path);
TagReadResult? Read(string path);                 // { Track, Artwork, Lyrics, EmbeddedCueSheet }
Task WriteAsync(string path, TagEdit edit, ...);  // null = don't touch, empty/0 = clear
string? ReadLyrics(string path);  byte[]? ReadArtwork(string path);
```
`TagEdit`: Title, Artist, Album, AlbumArtist, Genre, Composer, Year?, TrackNumber?, TrackTotal?,
DiscNumber?, DiscTotal?, Bpm?, Comment, Lyrics, Artwork (byte[]?), RemoveArtwork,
MusicBrainzRecordingId, MusicBrainzReleaseId. After `WriteAsync`, call
`ILibraryScanner.ScanFilesAsync` so the library picks up the change.

## Artwork — `IArtworkCache`

```csharp
Task<string> StoreAsync(byte[] data);                       // returns hash (SHA1 hex)
Task<string?> StoreFromUrlAsync(string url, headers = null);
string? GetPath(string? hash);                              // full-size image file path
string? GetThumbnailPath(string? hash, int size = 256);     // generated on demand
string? FindFolderImage(string folder);
Task<long> GetSizeAsync();
```
UI pattern: `track.ArtworkHash is { } h ? artwork.GetThumbnailPath(h, 96) : null`, and bind an Image to
the file path. `track.ArtworkUrl` is a remote fallback (download via `StoreFromUrlAsync`).

## Lyrics — `ILyricsService` + `LrcParser` (MuurMusic.Core.Lyrics)

```csharp
Task<LyricsResult> GetAsync(Track, bool allowOnline = true);  // saved → sidecar → embedded → online (LRCLIB)
Task<LyricsResult?> FetchOnlineAsync(Track);
Task SaveAsync(Track, string lrcOrText, bool embedInFile = false);
Task DeleteCachedAsync(Track);
Task<long> GetOffsetAsync(Track);  Task SetOffsetAsync(Track, long offsetMs);
```
`LyricsResult { Document, Origin, RawText, Found }`. `LyricsDocument`: `Lines` (each
`LyricLine(long? TimeMs, string Text, IReadOnlyList<LyricWord> Words)`), `IsSynced`, `OffsetMs`
(already applied to line times), `Title/Artist/Album/Author`, `LengthMs`, `Tags`, `IsEmpty`,
`int LineIndexAt(long positionMs, long extraOffsetMs = 0)` (binary search; feed it
`playback.Position.TotalMilliseconds` each tick), `ToPlainText()`, `ToLrc()`, `Shift(deltaMs)`.
`LrcParser.Parse(text)`, `LrcParser.LooksSynced(text)`, `LrcParser.FormatTime(ms)`.

## Playlists — `IPlaylistRepository`, `IPlaylistIoService`, smart playlists

`Playlist { Id, Name, Kind (Normal|Smart), Smart?, TrackCount, DurationMs, Created, Updated, SortOrder,
ArtworkHash }`; `PlaylistEntry { Id, PlaylistId, Position, TrackId?, SourceUri, CueStartMs, Title,
Artist, DurationMs, Track? }`.

```csharp
// IPlaylistRepository
Task<IReadOnlyList<Playlist>> GetAllAsync();  Task<Playlist?> GetAsync(long id);
Task<Playlist> CreateAsync(string name, SmartPlaylistDefinition? smart = null);
Task<Playlist> DuplicateAsync(long id, string newName);
Task RenameAsync(long id, string name);  Task UpdateSmartAsync(long id, SmartPlaylistDefinition);
Task DeleteAsync(long id);  Task SetSortOrderAsync(IReadOnlyList<long> idsInOrder);
Task<IReadOnlyList<PlaylistEntry>> GetEntriesAsync(long playlistId);
Task AddTracksAsync(long playlistId, IEnumerable<Track>, int? position = null);
Task RemoveEntriesAsync(long playlistId, IEnumerable<long> entryIds);
Task MoveEntryAsync(long playlistId, int from, int to);
Task ReorderAsync(long playlistId, IReadOnlyList<long> entryIdsInOrder);
Task ClearAsync(long playlistId);

// IPlaylistIoService (MuurMusic.Core.Playlists)
IReadOnlyList<string> ImportExtensions { get; }               // .m3u .m3u8 .pls .cue .json
PlaylistFileFormat FormatFromPath(string path);               // M3u|M3u8|Pls|Cue|SmartJson
Task<PlaylistImportResult> ImportAsync(string path, string? name = null);   // { Playlist, Imported, Missing }
Task<IReadOnlyList<Track>> ReadTracksAsync(string path);      // parse without importing
Task<IReadOnlyList<Track>> GetTracksAsync(long playlistId, bool availableOnly = false);  // resolves smart
Task ExportAsync(long playlistId, string path, PlaylistFileFormat);
Task ExportTracksAsync(IEnumerable<Track>, string path, PlaylistFileFormat, string? title = null);
```

Smart playlist JSON (`docs/specs/SHARED_FORMATS.md`, format marker `muur-smart`):
`SmartPlaylistDefinition { Name, Match ("all"|"any"), Rules, Sort, Limit }`,
`SmartRule { Field, Op, Value, Value2 }`. Supported fields and ops:
`SmartPlaylistCompiler.SupportedFields` / `.SupportedOps` (`is, isNot, contains, startsWith, gt, lt,
between, inLast`). `SmartPlaylistCompiler.Compile(def) → CompiledSmartQuery` is what the repository uses.
Get the live track list for a smart playlist via `IPlaylistIoService.GetTracksAsync` or
`ITrackRepository.QuerySmartAsync`.

## EQ & DSP presets — `IPresetService` (MuurMusic.Core.Dsp)

```csharp
IReadOnlyList<EqPreset> BuiltInEqPresets { get; }             // parsed from docs/specs/eq-presets.json
Task<IReadOnlyList<EqPreset>> GetEqPresetsAsync();            // built-ins + custom
Task<EqPreset?> FindEqPresetAsync(string name);
Task SaveEqPresetAsync(EqPreset);   // custom only; built-in names rejected
Task RenameEqPresetAsync(old, new); Task DeleteEqPresetAsync(name);
Task<IReadOnlyList<EqPreset>> ImportEqPresetsAsync(path);  Task ExportEqPresetsAsync(path, presets);
Task<IReadOnlyList<DspChain>> GetDspChainsAsync();
Task SaveDspChainAsync(DspChain);  Task DeleteDspChainAsync(name);
Task<DspChain> ImportDspChainAsync(path);  Task ExportDspChainAsync(path, chain);
```
`EqPreset { Name, PreampDb, Bands (10 × EqBand(FrequencyHz, GainDb)), IsBuiltIn }`, max gain ±12 dB,
`EqPreset.IsoFrequencies` = 31…16000 Hz. `DspChain { Name, Nodes }`, `DspNode { InstanceId (runtime only),
Type, Enabled, Params (string→double), RawParams }`. Node catalog: `DspNodeTypes.All`,
`GetLabel(type)`, `GetParams(type) → IReadOnlyList<DspParamSpec(Name, Label, Min, Max, Default, Unit,
IsInteger, Logarithmic)>` — use this to build the DSP editor UI generically. Types: `lowPass, highPass,
bandPass, notch, peaking, lowShelf, highShelf, gain, softClip, bitCrusher, tremolo, delay, ringModulator,
stereoWidth, reverb, chorus, flanger, phaser, autoWah, distortion, compressor, crossfeed`.
Applying to playback: write `AppSettings.EqEnabled/EqPresetName/EqPreampDb/EqBands` or
`DspChainEnabled/DspChainJson` (serialize with `DspJson.WriteDspChain`); playback picks it up live.
`DspJson.ReadEqPresets/WriteEqPresets/ReadDspChain/WriteDspChain` implement the shared formats.

## Sources — `ISourceManager` (MuurMusic.Core.Sources)

```csharp
IReadOnlyList<IMusicSource> Sources { get; }   IMusicSource LocalSource { get; }
RemovableDrives RemovableDrives { get; }        // USB monitor; fires SourcesChanged
event EventHandler SourcesChanged;
IMusicSource? Get(Guid id);  IMusicSource? FindForUri(string uri);
Task<IMusicSource> AddAsync(SourceConfig, IReadOnlyDictionary<string,string?>? secrets = null, bool testConnection = true);
Task<IMusicSource> UpdateAsync(SourceConfig, secrets = null);
Task RemoveAsync(Guid id);                      // deletes stored credentials too
Task SetSecretsAsync(Guid sourceId, secrets);   // rotate credentials
Task<MediaLocation> ResolveAsync(string uri);   Task<MediaLocation> ResolveTrackAsync(Track);
Task<Track?> GetTrackAsync(string uri);
```

`IMusicSource`: `Config`, `Kind`, `Capabilities` (flags: Browse, Search, Write, MediaLibrary), `RootUri`,
`Owns(uri)`, `TestConnectionAsync()`, `ListAsync(folderUri = null) → IReadOnlyList<SourceItem>`,
`ResolveAsync(uri) → MediaLocation`, `SearchAsync(query)`, `GetTrackAsync(uri)`,
`CreateFolderAsync/RenameAsync/DeleteAsync/UploadAsync` (throw when unsupported).
`SourceItem { Uri, Name, Kind (Folder|Audio|Playlist|Archive|Image|Artist|Album|Genre|Library|Other),
Size, Modified, Track?, ArtworkUrl, Subtitle, ChildCount, IsFolder, IsPlayable }`.
`MediaLocation { Kind (File|Url|Stream), Path, Url, Headers, Length, MimeType, FileName,
IsCachedCopy, IsRemote }` — you never open these yourself; the playback engine does.

`SourceConfig { Id, Kind, Name, Settings (string dict), SortOrder, Enabled }` with helpers
`Get/GetInt/GetBool/Set`. `SourceKind`: `Local, Smb, WebDav, Ftp, Sftp, Upnp, S3, Dropbox, GoogleDrive,
OneDrive, Box, PCloud, Subsonic, Jellyfin, Emby, Plex, Zip`.
Setting keys (`SourceKeys`): `host, port, path, share, domain, username, baseUrl, useTls, implicitTls,
acceptAnyCertificate, authMode, endpoint, region, bucket, pathStyle, serverId, serverUrl, userId,
legacyAuth, archiveUri`. Secrets (never in `Settings`, passed via `secrets` dict, stored DPAPI-encrypted):
`SourceKeys.SecretPassword, SecretPrivateKey, SecretPassphrase, SecretAccessKey, SecretSecretKey,
SecretToken, SecretOAuth`.

Errors: `SourceException` (readable message), `SourceAuthenticationException` (bad credentials → prompt
again), `OAuthNotConfiguredException` (missing client id), `OfflineException` (offline mode, no cached copy).

### OAuth (Dropbox, GoogleDrive, OneDrive, Box, PCloud) — `IOAuthService`

Client ids come from `appsettings.json` (or `appsettings.Local.json`, gitignored): keys
`OAuth:<Provider>:ClientId`, optional `OAuth:<Provider>:ClientSecret`, `OAuth:<Provider>:RedirectPort`.
Providers: `OAuthProviders.Dropbox/GoogleDrive/OneDrive/Box/PCloud`.

```csharp
bool IsConfigured(string provider);                 // hide the provider button when false
Task AuthorizeSourceAsync(SourceConfig config);     // opens browser, loopback redirect, stores token
Task<OAuthToken> GetTokenAsync(SourceConfig, bool forceRefresh = false);  // auto-refresh
Func<Uri, Task>? BrowserLauncher { get; set; }      // override how the URL is opened
```
Add-flow for a cloud source: build `SourceConfig`, call `oauth.AuthorizeSourceAsync(cfg)` (throws
`OAuthNotConfiguredException` when unconfigured), then `sources.AddAsync(cfg)`.

Plex is different: `PlexAuthService` (registered in DI) implements the plex.tv PIN flow —
`StartPinAsync()` → show URL/QR → `await WaitForPinAsync(...)` → returns token; then a Plex source with
`SourceKeys.SecretToken` lists the user's servers.

### Network discovery — `INetworkDiscovery` (MuurMusic.Core.Discovery)

```csharp
Task<IReadOnlyList<DiscoveredServer>> ScanAsync(TimeSpan duration, Action<DiscoveredServer>? found = null);
```
`DiscoveredServer { Kind (Smb|WebDav|Sftp|Ftp|Upnp|Jellyfin|Emby|Plex), Name, Host, Port, Url, Id,
Properties }` and `ToSourceConfig()` — mDNS + SSDP + broadcast probes; call with ~4-6 s from the
"add source" dialog, stream results via the callback.

### Credentials — `ICredentialStore` (MuurMusic.Core.Security)

DPAPI-encrypted (per-user) key/value store on disk. UI normally never touches it directly — pass secrets
through `ISourceManager.AddAsync/UpdateAsync/SetSecretsAsync`. Extensions:
`GetSourceSecretAsync/SetSourceSecretAsync(sourceId, name, value)`, `RemoveSourceSecretsAsync(sourceId)`.

## Downloads & offline — `IDownloadManager` (MuurMusic.Core.Downloads)

```csharp
Task InitializeAsync();                            // done by MuurCoreStartup
IReadOnlyList<DownloadItem> Items { get; }
event EventHandler<DownloadItem> ItemChanged;      // progress/state updates (via dispatcher)
event EventHandler ItemsChanged;                   // list membership changed
event EventHandler<(string SourceUri, string? LocalPath)> OfflineCopyChanged;

Task<IReadOnlyList<DownloadItem>> MakeAvailableOfflineAsync(IEnumerable<Track>);
Task RemoveOfflineCopyAsync(Track);
Task<IReadOnlyList<DownloadItem>> DownloadToFolderAsync(IEnumerable<Track>, string? folder = null);
Task<DownloadItem> DownloadUriAsync(string sourceUri, string? fileName = null, string? folder = null);
Task CacheTrackAsync(Track);                       // playback already calls this
void Pause(Guid id);  void Resume(Guid id);  void Retry(Guid id);
Task CancelAsync(Guid id);  Task RemoveAsync(Guid id, bool deleteFile = false);
void PauseAll();  void ResumeAll();  Task ClearFinishedAsync();
Task ClearCacheAsync();  Task EnforceCacheLimitAsync();
Task<long> GetCacheSizeAsync();  long GetOfflineSize();
```
`DownloadItem { Id, SourceUri, TrackId?, Title, Artist, DestinationPath, TotalBytes, DownloadedBytes,
State (Queued|Downloading|Paused|Completed|Failed|Canceled), Kind, Error, ... }` — drive a downloads page
from `Items` + the two events. Progress is throttled; read `DownloadedBytes/TotalBytes`.

## Queue persistence — `IQueueStore` (MuurMusic.Core.Playback)

Used internally by the playback service (`RememberQueue` setting). The UI does not need it.
`QueueSnapshot` JSON lives at `AppPaths.QueuePath`.

## Infrastructure bits

- `AppPaths` (registered): `Root, DatabasePath, SettingsPath, QueuePath, CredentialsPath,
  ArtworkDirectory, ThumbnailDirectory, LyricsDirectory, AudioCacheDirectory, ArchiveCacheDirectory,
  OfflineDirectory, LogsDirectory, DownloadsTempDirectory`, `DefaultDownloadFolder`.
  Root = `%LOCALAPPDATA%\MuurMusic`, overridable via env `MUURMUSIC_DATA` or `MuurCoreOptions.DataRoot`.
- `HttpClientNames.Default` ("muur") — resolve via `IHttpClientFactory` if the UI needs HTTP.
- Logging: file logger writes to `AppPaths.LogsDirectory`; set `MuurCoreOptions.DebugLogging` /
  `MinimumLogLevel`.
- `MuurMusic.Core.Sources.AwsSigV4` — public static AWS Signature V4 implementation (used by S3 sources;
  unit-tested against the AWS get-vanilla reference vector).
- `MuurMusic.Core.Models.AudioFormats` — extension lists, `IsLosslessCodec`, `FormatBadge`,
  `TagLibExtensions`.

---

# Audio layer (MuurMusic.Audio)

## The facade: `IPlaybackService` (MuurMusic.Audio.Playback)

This is the only audio service the UI needs for playback. Everything is serialized internally; call from
any thread.

```csharp
// State
PlayQueue Queue { get; }                 // read-only view is fine; mutate through the methods below
PlayerState State { get; }               // Stopped | Playing | Paused | Buffering
Track? CurrentTrack { get; }             Guid? CurrentEntryId { get; }
TimeSpan Position { get; }               // poll on a UI timer (250-500 ms)
TimeSpan Duration { get; }
bool IsBuffering { get; }  bool IsCasting { get; }
bool StopAfterCurrent { get; set; }
double Volume { get; set; }              // 0..1 slider; perceptual taper applied internally
bool Muted { get; set; }
double Speed { get; set; }               // 0.5..2.0, pitch-preserving (WSOLA)
bool Shuffle { get; set; }               // persisted to settings
RepeatMode Repeat { get; set; }          // Off|All|One; persisted
TimeSpan? SleepTimerRemaining { get; }   void SetSleepTimer(TimeSpan?);   // 10 s fade-out at the end

// Events (raised via IEventDispatcher → UI thread when a poster is set)
event EventHandler StateChanged;                       // State/IsBuffering/pause-resume transitions
event EventHandler QueueChanged;
event EventHandler<PlaybackTrackEventArgs> TrackChanged;       // { Track, EntryId }
event EventHandler<PlaybackErrorEventArgs> PlaybackError;      // { Message, Track?, Exception? } — show a toast
event EventHandler OutputDevicesChanged;               // re-read GetOutputDevices()

// Lifecycle
Task InitializeAsync(IntPtr mainWindowHandle, ...);    // SMTC + queue restore; pass the app's HWND
Task FlushAsync();                                     // call on app exit (queue/position/settings)

// Playback
Task PlayAsync(IReadOnlyList<Track> tracks, int startIndex = 0, TimeSpan? startPosition = null);
Task PlayEntryAsync(Guid entryId);                     // queue item by id (from Queue.Items)
Task PlayAtIndexAsync(int index);                      // queue item by list index
void EnqueueNext(IEnumerable<Track>);  void EnqueueLast(IEnumerable<Track>);
Task RemoveFromQueueAsync(IEnumerable<Guid> entryIds);
void MoveQueueEntry(int from, int to);
Task ClearQueueAsync();
Task TogglePlayPauseAsync();  Task PlayAsync();  Task PauseAsync();  Task StopAsync();
Task NextAsync();  Task PreviousAsync();               // Previous = restart when >3 s in
Task SeekAsync(TimeSpan);
Task SkipBackAsync();  Task SkipForwardAsync();        // use settings.SkipBack/ForwardSeconds

// Bookmarks
Task<Bookmark?> AddBookmarkAsync(string? note = null); // at current position
Task GoToBookmarkAsync(Bookmark);

// Output devices
IReadOnlyList<OutputDeviceInfo> GetOutputDevices();    // { Id, FriendlyName, IsDefault, IsActive }
Task ReopenOutputAsync();                              // re-apply settings.OutputDeviceId/ExclusiveMode/...

// Casting
ICastManager Cast { get; }
Task ConnectCastAsync(CastDeviceInfo);                 // hands off seamlessly at current position
Task DisconnectCastAsync(bool resumeLocally = true);   // ...and back

// Escape hatches for the UI (visualizers, DSP editors)
AudioEngine Engine { get; }       // .Spectrum, .Meter for visualizer polling
IAudioOutput Output { get; }      // .Format, .Latency for the "now playing" details pane
SmtcService Smtc { get; }         // already wired; rarely needed directly
```

Behavior notes:
- Gapless and crossfade are automatic between queue entries (settings `Gapless`, `CrossfadeSeconds`).
- Next track is decoded/buffered ahead (`PrefetchNextTrack`, `StreamBufferSeconds`) — no UI work needed.
- Plays are recorded automatically (≥30 s played or completed → play count; early manual skip → skip count).
- Queue + position persist automatically when `RememberQueue` is on; restored in `InitializeAsync`,
  resumed when `ResumePlaybackOnStartup` is on.
- When the selected output device vanishes, playback falls back to the default device and
  `OutputDevicesChanged` fires. `PlaybackError` fires when a track fails; the queue advances past it.
- `Speed` changes are gapless (no restart). The seek bar should use `Position`/`Duration` only.

`PlayQueue` surface (for rendering the queue list): `Items` (`QueueEntry { EntryId, Track }`), `Count`,
`Shuffle`, `Repeat`, `CurrentIndex` (list index of current), `Current`, `Order`/`OrderPosition`
(shuffle order), `Changed`. Do not call its mutators from the UI — use the service.

## SMTC (system media transport controls) — `SmtcService` (MuurMusic.Audio.Smtc)

Fully wired by `IPlaybackService`: metadata, artwork, play/pause/next/previous, seek, shuffle/repeat
toggles, position timeline. The UI only needs to pass the real main-window `HWND` to
`InitializeAsync` (SMTC `GetForWindow` fails with `E_ACCESSDENIED` for any other window).

## Casting — `ICastManager` (MuurMusic.Audio.Casting)

```csharp
bool IsActive { get; }  CastDeviceInfo? ActiveDevice { get; }
TimeSpan Position { get; }  bool IsPlaying { get; }
event EventHandler ActiveDeviceChanged;
event EventHandler SessionStateChanged;        // position/play state on the cast device
event EventHandler SessionTrackEnded;          // handled internally; informational
event EventHandler SessionLost;                // device disappeared (playback already stopped)
Task<IReadOnlyList<CastDeviceInfo>> DiscoverAsync(TimeSpan duration, ...);
```
`CastDeviceInfo { Id, Name, Transport (Chromecast|Dlna), Model }`. Flow: `DiscoverAsync(~4 s)` → user
picks one → `playback.ConnectCastAsync(device)` (the current track keeps playing on the device; local
output closes) → control via the usual `IPlaybackService` methods → `DisconnectCastAsync()` resumes
locally at the same position. `settings.LastCastDeviceId` remembers the last device.

## Output — `IAudioOutput` (MuurMusic.Audio.Output)

`WasapiOutput` implementation. Shared mode = float32 at the engine mix rate; exclusive mode negotiates
float32 → int32 → int24-in-32 → int24 → int16 at the requested rate (or the source rate when
`settings.OutputSampleRate == 0`, giving bit-perfect rate switching). Members: `GetDevices()`,
`DeviceId`, `DeviceName`, `Format` (`OutputFormatInfo { SampleRate, Channels, Encoding, ValidBits,
Exclusive }`), `IsOpen`, `IsPlaying`, `Latency`, `Prepare(...)`, `Start(engine)`, `PausePlayback()`,
`ResumePlayback()`, `Close()`; events `PlaybackError`, `DeviceListChanged`, `DefaultDeviceChanged`.
The playback service owns all of this; the UI only calls `GetOutputDevices()` and writes settings.

## Engine & DSP building blocks (for visualizers / DSP editor)

- `AudioEngine` (`MuurMusic.Audio.Engine`): the mixer. Public state: `State`, `IsBuffering`,
  `Volume` (slider 0..1, cubic taper), `Muted`, `Speed`, `Gapless`, `GapMilliseconds`,
  `CrossfadeSeconds` (0..12, equal-power), `NextTrackLeadSeconds`, `Position`, `Duration`, `Current`,
  `SampleRate`, `Channels`, `Dsp` (`DspProcessor`), `Meter` (`AudioMeter`), `Spectrum`
  (`SpectrumAnalyzer`). Events (`TrackStarted`, `TrackFinished`, `NextTrackNeeded`, `Ended`,
  `BufferingChanged`, `PausedCompletely`, `Error`) fire on an internal pump thread — do not subscribe
  from the UI; use `IPlaybackService` events.
- `AudioMeter`: `void Write(samples, channels)`; read `PeakL/PeakR` (0..1, decaying) — poll per frame.
- `SpectrumAnalyzer`: `SampleRate` settable; `Write(ReadOnlySpan<float>, int channels)` is fed by the
  engine; UI calls `GetSpectrum(Span<float> bands)` (any band count, log-spaced, smoothed; values 0..1
  against `MinDb/MaxDb`) and `GetWaveform(Span<float>)`.
- `DspProcessor`: `Configure(rate, ch)`, `SetEqualizer(enabled, preampDb, gains[10])`,
  `SetEqualizer(enabled, EqPreset)`, `SetLoudness(enabled, boostDb)`, `SetChain(enabled, DspChain)`,
  `SetChainJson(enabled, json)`, `UpdateNode(DspNode)`, `Reset()`, `Process(Span<float>)`, `IsActive`,
  `LimiterGainReductionDb`. The playback service already syncs it from settings — use these only for
  live preview in the DSP editor.
- `GraphicEqualizer`: `BandCount` = 10, `Frequencies`, `Set(preampDb, gains)`, `Process`, `Enabled`,
  `ResponseDbAt(freq)`, static `ResponseDb(preamp, gains, freq)` (for drawing the EQ curve).
- `BiquadCoefficients.Create(BiquadType, sampleRate, frequency, q, gainDb)` + `MagnitudeDbAt` /
  `ResponseAt` for response curves; `BiquadFilter` for processing.
- `ReplayGain.LinearGain(track, mode, preampDb, untaggedDb, preventClipping)`.
- `WsolaTimeStretcher`: pitch-preserving 0.5x-2.0x; used internally for `Speed`.

## Decoding — FFmpeg

`FFmpegLoader.EnsureLoaded()` runs lazily on first decode; `FFmpegLoader.RootPath` is where DLLs were
found (app base directory, then PATH). `FFmpegDecoder.OpenFile/OpenUrl/OpenStream/Open(MediaLocation,
...)` implement `IAudioDecoder` (`Info: AudioStreamInfo { SampleRate, Channels, BitDepth, Codec,
Container, Duration, BitrateKbps, IsDsd, IsLossless }`, `Read(Span<float>)`, `Seek(TimeSpan)`,
`SetOutputFormat`, `CanSeek`). **You should not need these directly** — the playback service decodes.
`IMediaProbe` (DI) is enough for metadata: `Task<MediaProbeResult?> ProbeAsync(string location, headers)`.

### Native DLL deployment (important for the App project)

The app must ship the FFmpeg 7.1 shared libraries next to the executable: `avcodec-61.dll`,
`avformat-61.dll`, `avutil-59.dll`, `swresample-5.dll`, `swscale-8.dll` (and their dependencies
`postproc-58.dll` if referenced). They come from the `Sdcb.FFmpeg.runtime.windows-x64` NuGet package —
adding `<PackageReference Include="Sdcb.FFmpeg.runtime.windows-x64" />` to the App project copies them
to the output automatically. `FFmpegLoader` also searches PATH as a fallback.

## File-format parsers (also in Core, all unit-tested)

- `M3uFormat.Parse/Write` (EXTINF, relative+UNC+URL paths) and `PlsFormat` — `MuurMusic.Core.Playlists`.
- `CueSheet.Parse/Write/ToVirtualTracks` — multi-file CUE, frames→ms at 75 fps, embedded CUE from tags.
- `LrcParser` — synced/plain/enhanced LRC (see Lyrics above).
- `SmartPlaylistCompiler` / `DspJson` — `muur-smart`, `muur-eq`, `muur-dsp` formats (see
  `docs/specs/SHARED_FORMATS.md`).

## Known platform notes

- SMTC uses a verified COM vtable interop (`SystemMediaTransportControlsInterop.GetForWindow`); it is
  inert when `InitializeAsync` is called with `IntPtr.Zero` or before the window exists — safe to retry.
- Exclusive-mode WASAPI format negotiation depends on hardware; failure falls back to shared mode and is
  reported through `PlaybackError`/log.
- Chromecast/DLNA sessions poll device state once per second; `Position` while casting has ~1 s latency.
- All events except `AudioEngine.*` are delivered through `IEventDispatcher` — set the poster once at
  startup and never worry about cross-thread UI access again.
