# MuurKit API Reference

Swift package `MuurKit` (`apple/Packages/MuurKit`), products: **MuurCore**, **MuurAudio**,
**MuurWidgetKitSupport**. Platforms: iOS 17+, macOS 14+. Swift 5 language mode (tools 5.10);
strict concurrency diagnostics are warnings, not errors.

## Bootstrap

```swift
import MuurCore
import MuurAudio

// App entry point (once; idempotent):
let environment = try MuurEnvironment.bootstrap(appGroup: "group.app.muur.music")
// Audio facade (main actor):
let player = PlaybackController(environment: environment)
```

`bootstrap(appGroup:keychainAccessGroup:)` starts the download queue, registers the default
"Documents" library folder, runs an incremental scan and starts folder monitoring.
`MuurEnvironment.inMemory(appGroup:)` builds a non-persistent graph for previews and tests.

```swift
// Scene body:
.onOpenURL { url in Task { await environment.handleOpenURL(url) } }
```

iOS background downloads — forward the app delegate callback:

```swift
func application(_ application: UIApplication,
                 handleEventsForBackgroundURLSession identifier: String,
                 completionHandler: @escaping () -> Void) {
    if MuurEnvironment.shared?.downloads.handleBackgroundEvents(identifier: identifier,
                                                                completionHandler: completionHandler) != true {
        completionHandler()
    }
}
```

## Threading and observation

- `MuurEnvironment`, `PlaybackController`, `DownloadManager`, `LibraryScanner`, `AudioLevelMonitor`,
  `WiFiTransferServer`, `AudioSessionManager` (iOS), `NowPlayingManager`, `WidgetSnapshotWriter`,
  `OAuthManager` are `@MainActor` `ObservableObject`s — bind with `@StateObject` / `@ObservedObject`.
- `MuurDatabase` (`read`/`write`/`observe`), `LibraryRepository`, `PlaylistStore`, `AudioPresetStore`,
  `SourceManager`, `AudioCache`, `CredentialStore`, `HTTPClient`, `MusicBrainzClient`, `TagEditor`,
  `MetadataLookupService`, `LyricsService` are `Sendable` and callable from any context.
- Database observation: `MuurDatabase.observe { db in ... }` returns an `AsyncSequence`
  (GRDB `ValueObservation`) that re-fetches on every commit touching the read tables.
- Engine events arrive on unspecified threads; `PlaybackController` already hops to the main actor.
- The DSP audio unit and level tap never lock or allocate on the render thread; parameter changes
  swap immutable snapshots (`DSPProgram`) under a short lock.

## MuurCore public API

### Environment & support
- `MuurEnvironment` — service graph: `paths`, `defaults`, `settings`, `database`, `repository`,
  `playlists`, `presets`, `artwork`, `scanner`, `tagEditor`, `lyrics`, `musicBrainz`, `metadata`,
  `credentials`, `audioCache`, `sources`, `downloads`, `discovery`, `wifiTransfer`, `widgetStore`;
  `bootstrap`, `inMemory`, `start()`, `handleOpenURL(_:)`.
- `MuurSettings` — `@Published` user preferences (EQ bands/preamp, DSP chain JSON, loudness,
  ReplayGain mode/preamp/clipping, crossfade, gapless, playback speed, skip intervals, sleep fade,
  DSD mode, macOS output device/sample-rate, Wi-Fi transfer port/PIN, offline/cache/download policy,
  accent, resume on launch...). `MuurSettings.Snapshot.current(defaults:)` reads policy values
  nonisolated. Enums: `ThemePreference`, `AccentChoice`, `ReplayGainMode`, `DSDPlaybackMode`,
  `OutputSampleRateMode`.
- `AppPaths` — app-group/document locations (`musicFolder`, `downloadsDirectory`,
  `audioCacheDirectory`, `resumeDataDirectory`, `archiveExtractionDirectory`, `databaseURL`,
  `queueStateURL`, `widgetStore`), `createDirectories()`, `resolveStoredFileURL`.
- `MuurError` (LocalizedError): `notConfigured`, `unsupported`, `notFound`, `network`,
  `http(status:message:)`, `authenticationFailed`, `invalidData`, `protocolError`, `io`,
  `cancelled`, `offline`. `Log` — `os.Logger` categories.
- `HTTPClient` — `data(for:validate:)`, `data(from:headers:)`, `json`, `download(_:to:progress:)`;
  User-Agent `MuurMusic/1.0 ( https://muur.app )`. `URLRequest(url:method:headers:body:)` convenience,
  `URLComponents.setQuery`, `FormEncoding.encode`.
- Utilities: `Hashing` (sha256/md5/hmacSHA256/random/base64URL), `PathUtils` (audioExtensions,
  percentEncodePath, rfc3986Encode, sanitizeFileName, titleFromFileName, mimeType, isAudio/isPlaylist/isArchive),
  `DateParsing`, `RateLimiter`, `LockedValue`, `XMLTree`/`XNode`, `AudioFormatSniffer` (magic bytes),
  `SecurityScopeManager`, `UbiquityHelper` (iCloud placeholders).

### Models
- `Track` (GRDB record + display helpers `displayTitle`/`displayArtist`/`displayAlbum`,
  `formatBadge`, `isCueTrack`, ReplayGain fields, CUE window, MusicBrainz IDs), `TrackSortField`,
  `TrackSort`, `Album`, `Artist`/`LibraryGroup`, `LibrarySnapshot`.
- `Playlist`, `PlaylistItem`, `SmartPlaylistDefinition`/`SmartRule`/`SmartRuleField`/
  `SmartRuleOperator`/`SmartMatch` (`muur-smart` format).
- `SourceConfig`, `SourceKind` (all 17 kinds), `SourceSecrets`, `SourceURI`
  (`parse`, `file(_:)`, `zip(inner:entry:)`, `idBasedSchemes`), `RemoteResource`.
- `WatchedFolder`, `PlayHistoryEntry`, `DownloadItem`/`DownloadState`.
- `EQBand`, `EQPreset`, `EQPresetFile` (`muur-eq`), `DSPNodeType` (22 effects), `DSPNode`,
  `DSPChain` (`muur-dsp`), `JSONValue`.

### Database
- `MuurDatabase(url:)` / `.inMemory()` — GRDB pool, forward-only migrations, FTS5 search table.
- `LibraryRepository` — sources CRUD + observation, track upsert, `recordPlay`, `recordSkip`,
  `recentlyPlayed`, favorites/rating.
- `LibraryQueries` — filtered/sorted track, album and artist queries, `downloads(db)`, search.
- `PlaylistStore` — playlists CRUD, smart playlists, M3U/PLS import/export.
- `AudioPresetStore` — built-in EQ presets from bundled `eq-presets.json` (13 presets) + user
  presets and DSP chains.
- `SmartPlaylistCompiler` — rules → parameterized SQL (`CompiledSmartQuery.fetch(_:)`).

### Library
- `LibraryScanner` (`@MainActor`) — `scanAll(full:)`, `scan(folderID:full:)`, `importFiles(_:)`,
  `ensureDefaultFolder()`, `startMonitoring()`; writes artwork to `ArtworkCache`.
- `ArtworkCache` — `thumbnailData(for:size:)` (`Size.small/medium/large/widget`), `originalURL(for:)`.
- `TagEditor` — read/write tags via SFBAudioEngine (`MetadataReader`); embedded artwork updates.
- `FolderMonitor` — FSEvents (macOS) / DispatchSource (iOS) directory watching.

### Lyrics & metadata
- `LyricsService` — sidecar/embedded/online lyrics, `Lyrics`, `LyricLine`, `LRCParser`,
  `LyricsOrigin`.
- `MusicBrainzClient` (rate-limited ≤1 req/s, MuurMusic UA), `MetadataLookupService`
  (recording/release lookup + Cover Art Archive artwork).
- Formats: `CueSheet`/`CueTrack` (75 fps indexes), `M3UPlaylist`, `PLSPlaylist`,
  `PlaylistPathResolver`, `TextDecoding`.

### Sources
- `MusicSource` protocol — `config`, `capabilities` (`SourceCapabilities`), `connect`, `list`,
  `download(uri:to:progress:)`, `streamURL(for:)`, `search`, `libraryTracks(progress:)`, upload /
  delete / rename / createFolder where supported.
- Implementations: `LocalSource`, `WebDAVSource`, `SMBSource` (AMSMB2), `SFTPSource` (Citadel),
  `FTPSource`, `UPnPSource` (DLNA servers), `S3Source` (+ `S3Signer` SigV4), `SubsonicSource`,
  `JellyfinSource` (also Emby), `PlexSource`, `DropboxSource`, `GoogleDriveSource`,
  `OneDriveSource`, `BoxSource`, `PCloudSource`, `ZipArchiveSource` (ZIPFoundation).
- `SourceManager` — factory/cache, `configs()`/`save`/`test`/`remove`, `source(forURI:sourceID:)`,
  `playableURL(for:)`, `remoteResource(for:)`, `prefetch`, `pinCached`, `syncLibrary`,
  `addToLibrary`, offline lookup.
- `SourceDiscovery` — Bonjour + SSDP discovery; `DiscoveredService`. `SSDPDiscovery`, `UPnPDevice`,
  `UPnPService`, `UPnPSOAP`, `DIDLParser`/`DIDLObject`.
- `OAuthManager.shared` (`@MainActor`) — `signIn(_:)`, `refresh`, `accountName`;
  `presentationAnchorProvider: (@MainActor () -> ASPresentationAnchor)?` presentation hook.
- `CredentialStore` — Keychain-backed secrets per source.

### Downloads & offline
- `DownloadManager` (`@MainActor`) — `@Published items`, `isWaitingForWiFi`,
  `maxConcurrentDownloads`; `enqueue`, `pause`/`resume`/`retry`/`remove`, `pauseAll`/`resumeAll`,
  Wi-Fi-only and offline gating, retry with backoff, background `URLSession` (identifier
  `app.muur.music.downloads`) for HTTP-like sources, in-process for the rest, ZIP auto-extraction,
  `handleBackgroundEvents(identifier:completionHandler:)`.
- `AudioCache` — LRU stream cache with content sniffing, pinning, configurable size limit.

### Wi-Fi transfer
- `WiFiTransferServer` (`@MainActor`) — `start(port:)`/`stop`, `@Published isRunning/port/urls/
  uploads/receivedFileCount/lastError`, `onFilesReceived` callback, optional PIN with lockout,
  `localIPv4Addresses()` (nonisolated). Serves the cat-themed upload page
  (`WiFiTransferPage`), multipart + raw upload, folder recursion, ZIP extraction, file
  download/delete API.

## MuurAudio public API

- `PlaybackController` (`@MainActor ObservableObject`) — full facade:
  - Queue: `play(_:startIndex:shuffle:)`, `playItem`, `playNext`, `addToQueue`, `removeFromQueue`,
    `moveInQueue`, `clearQueue`, `setShuffle`, `cycleRepeatMode`; `@Published queue`
    (`PlaybackQueue`, `QueueItem`, `ShuffleMode`, `RepeatMode`).
  - Transport: `togglePlayPause`, `pause`, `resume`, `stop`, `next`, `previous`, `seek(to:)`,
    `skipForward`, `skipBackward`, `setSpeed` (0.25–4 via `AVAudioUnitTimePitch`).
  - State: `@Published state/position/duration/isCrossfading/output/sleepTimer/sleepTimerEndsAt/
    lastError/volume`, `currentTrack`, `isPlaying`.
  - Sleep timer: `setSleepTimer(.off/.endOfTrack/.minutes(_))`, optional 5 s fade-out.
  - Output: local (two `PlaybackEngine`s, crossfade + gapless) or DLNA
    (`discoverRenderers`, `setRenderer`, `setLocalOutput`).
  - `audioSession` (iOS), `meters` (`AudioLevelMonitor`), `resumeRestoredQueue()`,
    `applyAudioSettings()`.
- `PlaybackQueue` — shuffled play order, `advance`/`back`/`jump`, `upNext(limit:)`; `QueueState`
  persistence (Codable).
- `AudioLevelMonitor` — `@Published levels/spectrum/spectrumFrequencies/isActive`,
  `framesPerSecond` (10–60), `attach(to:)`/`detach`; vDSP FFT (2048 → 512 dB bins).
  `AudioTapBuffer` ring buffer for render-thread capture.
- DSP: `DSPAudioUnit` (in-process `AUAudioUnit`, effect type "mupd") running the full `muur-dsp`
  chain + loudness contour + safety limiter + master fade; `DSPAudioNode` (engine insertion),
  `DSPProgram`/`DSPProgramBuilder`, all processors (`BiquadProcessor`, `GainProcessor`,
  `SoftClipProcessor`, `DistortionProcessor`, `BitCrusherProcessor`, `TremoloProcessor`,
  `RingModulatorProcessor`, `DelayProcessor`, `ModulatedDelayProcessor`, `PhaserProcessor`,
  `AutoWahProcessor`, `StereoWidthProcessor`, `CrossfeedProcessor`, `ReverbProcessor`,
  `CompressorProcessor`, `DSPLimiter`, `LoudnessContourProcessor`), `DSPFadeState`.
- `NowPlayingManager` — MPNowPlayingInfoCenter/MPRemoteCommandCenter wiring, artwork caching.
- `DLNARenderer` — AVTransport/RenderingControl control, `Position` polling;
  `LocalAudioServer` — tokenized Range-capable HTTP server for casting local files.
- iOS only (`#if !os(macOS)`): `AudioSessionManager` — category/activation, route-change and
  interruption handling.
- macOS only (`#if os(macOS)`): `AudioOutputDevice`/`AudioOutputDevices` — device enumeration by
  UID, `availableSampleRates`, `setNominalSampleRate` (bit-perfect rate matching), DoP heuristic.
- `WidgetSnapshotWriter` — writes the widget snapshot + artwork into the App Group and calls
  `WidgetCenter.reloadAllTimelines()` under `canImport(WidgetKit)`.

## MuurWidgetKitSupport

- `MuurAppGroup.identifier` (`group.app.muur.music`).
- `WidgetSharedStore` — `read()`/`write(_:)`, `writeArtwork(_:fileName:)`, `pruneArtwork(keeping:)`,
  `artworkURL(fileName:)`.
- `WidgetSnapshot`, `WidgetNowPlaying` (with `estimatedElapsed(at:)`), `WidgetQueueItem`,
  `WidgetLyricLine`, `lyricIndex(at:)`.

Widget extensions read the snapshot from the shared container and render from
`WidgetSharedStore.read()`; no app process needs to be running.

## App integration checklist

### Info.plist keys
| Key | Value |
|---|---|
| `MUUR_DROPBOX_CLIENT_ID` | Dropbox app key |
| `MUUR_GOOGLE_CLIENT_ID` | Google iOS/macOS client ID |
| `MUUR_ONEDRIVE_CLIENT_ID` | Microsoft application (client) ID |
| `MUUR_BOX_CLIENT_ID` / `MUUR_BOX_CLIENT_SECRET` | Box app credentials |
| `MUUR_PCLOUD_CLIENT_ID` | pCloud app key |
| `NSLocalNetworkUsageDescription` | e.g. "MuurMusic finds music servers on your network." |
| `NSBonjourServices` | `_smb._tcp`, `_webdav._tcp`, `_webdavs._tcp`, `_sftp-ssh._tcp`, `_ftp._tcp`, `_plexmediasvr._tcp` |

Missing cloud keys simply make the corresponding source kind report `MuurError.notConfigured`.

### URL schemes (`CFBundleURLTypes`)
- `muurmusic` — OAuth redirects (`muurmusic://oauth/<provider>`) and file imports.
- Google sign-in additionally needs the reversed client ID scheme
  (`com.googleusercontent.apps.<id>`) as its redirect scheme.

### Entitlements
- App Groups: `group.app.muur.music` (widgets, downloads state, shared artwork).
- Keychain Sharing (optional access group for `bootstrap(keychainAccessGroup:)`).
- iCloud: iCloud Documents (document storage in the ubiquity container is detected via
  `UbiquityHelper`).
- iOS: none else required. macOS: App Sandbox with network client + user-selected file access
  (read/write for library folders; downloads folder if used), plus
  `com.apple.security.network.multicast` (SSDP/Bonjour discovery on macOS 14+).
- Audio (macOS sandbox): `com.apple.security.device.audio-input` is **not** needed (output only).

### Background modes (iOS `UIBackgroundModes`)
- `audio` — continuous playback.
- `fetch` / `processing` (optional) — library refresh; not required for playback.
- Background URLSession transfers do not need a background mode, only the
  `handleEventsForBackgroundURLSession` forwarding shown above.

### Widgets
- Add a Widget Extension target depending on `MuurWidgetKitSupport` with the same App Group.
- The app writes snapshots through `PlaybackController` automatically; widget actions should deep
  link via the `muurmusic` URL scheme.

## Platform-conditional API summary

| API | iOS | macOS |
|---|---|---|
| `AudioSessionManager` | yes | no (`#if !os(macOS)`) |
| `AudioOutputDevices` / sample-rate matching | no | yes (`#if os(macOS)`) |
| `PlaybackController.volume` (device volume) | mirrored to DLNA only | local device volume + DLNA |
| DoP DSD output | converted to PCM | DoP when `dsdMode == .dop` |
| `MPNowPlayingInfoCenter.playbackState` | n/a | set |
| `WiFiTransferServer` device name | `UIDevice` | `SCDynamicStoreCopyComputerName` |

## Dependencies (pinned in Package.swift)

| Package | Version | Used for |
|---|---|---|
| SFBAudioEngine | upToNextMinor 0.14.0 | playback engine, decoders (DSD/DoP/regions), metadata/tag writing |
| GRDB.swift | from 7.12.0 | SQLite + FTS5 + ValueObservation |
| AMSMB2 | from 4.0.3 | SMB |
| Citadel | upToNextMinor 0.12.1 | SFTP/SSH |
| ZIPFoundation | upToNextMinor 0.9.20 | ZIP archives |
| swift-nio | from 2.81.0 | NIOCore (Citadel types) |
| swift-crypto | 3.12.3 ..< 5.0.0 | Crypto (Citadel key types) |
