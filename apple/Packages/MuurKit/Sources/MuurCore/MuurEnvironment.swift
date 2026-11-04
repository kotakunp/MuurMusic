import Foundation
import MuurWidgetKitSupport

/// The object graph of MuurCore services, created once at app launch with `MuurEnvironment.bootstrap(appGroup:)`.
///
/// ```swift
/// @main struct MuurMusicApp: App {
///     @StateObject private var environment = try! MuurEnvironment.bootstrap()
///     ...
/// }
/// ```
/// `MuurAudio.PlaybackController(environment:)` builds the audio engine on top of this graph.
/// Main-actor isolated; the contained `Sendable` services (`repository`, `sources`, ...) can be passed to any context.
@MainActor
public final class MuurEnvironment: ObservableObject {
    /// The environment created by `bootstrap` (nil before bootstrapping).
    public private(set) static var shared: MuurEnvironment?

    public let paths: AppPaths
    public let defaults: UserDefaults
    public let settings: MuurSettings
    public let database: MuurDatabase
    public let repository: LibraryRepository
    public let playlists: PlaylistStore
    public let presets: AudioPresetStore
    public let artwork: ArtworkCache
    public let scanner: LibraryScanner
    public let tagEditor: TagEditor
    public let lyrics: LyricsService
    public let musicBrainz: MusicBrainzClient
    public let metadata: MetadataLookupService
    public let credentials: CredentialStore
    public let audioCache: AudioCache
    public let sources: SourceManager
    public let downloads: DownloadManager
    public let discovery: SourceDiscovery
    public let wifiTransfer: WiFiTransferServer
    public var widgetStore: WidgetSharedStore { paths.widgetStore }

    private var started = false

    /// Creates the shared environment (idempotent: later calls return the existing instance) and starts
    /// background services: default library folder registration, an incremental library scan, folder
    /// monitoring (when `watchFolders` is on) and the offline download queue.
    ///
    /// - Parameters:
    ///   - appGroup: App Group shared with the widget extension (widget snapshot location).
    ///   - keychainAccessGroup: Keychain access group for source credentials (nil = the app's default group).
    @discardableResult
    public static func bootstrap(appGroup: String = MuurAppGroup.identifier, keychainAccessGroup: String? = nil) throws -> MuurEnvironment {
        if let shared { return shared }
        let environment = try MuurEnvironment(appGroup: appGroup, keychainAccessGroup: keychainAccessGroup,
                                              defaults: .standard, settings: .shared, inMemory: false)
        shared = environment
        environment.start()
        return environment
    }

    /// An environment backed by an in-memory database and separate defaults (SwiftUI previews, tests).
    /// Services are not started.
    public static func inMemory(appGroup: String = MuurAppGroup.identifier) throws -> MuurEnvironment {
        let suite = "app.muur.music.preview." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        return try MuurEnvironment(appGroup: appGroup, keychainAccessGroup: nil, defaults: defaults,
                                   settings: MuurSettings(defaults: defaults), inMemory: true)
    }

    private init(appGroup: String, keychainAccessGroup: String?, defaults: UserDefaults, settings: MuurSettings, inMemory: Bool) throws {
        let paths = AppPaths(appGroupIdentifier: appGroup)
        try paths.createDirectories()
        self.paths = paths
        self.defaults = defaults
        self.settings = settings
        let database: MuurDatabase
        if inMemory {
            database = try MuurDatabase.inMemory()
        } else {
            database = try MuurDatabase(url: paths.databaseURL)
        }
        self.database = database
        let repository = LibraryRepository(database: database)
        self.repository = repository
        playlists = PlaylistStore(database: database)
        presets = AudioPresetStore(database: database)
        let artwork = ArtworkCache(paths: paths)
        self.artwork = artwork
        scanner = LibraryScanner(database: database, artwork: artwork, paths: paths)
        tagEditor = TagEditor(repository: repository, artwork: artwork, paths: paths)
        lyrics = LyricsService(paths: paths, http: .shared, defaults: defaults)
        let musicBrainz = MusicBrainzClient(http: .shared)
        self.musicBrainz = musicBrainz
        metadata = MetadataLookupService(client: musicBrainz, artwork: artwork, repository: repository)
        let credentials = CredentialStore(service: CredentialStore.defaultService, accessGroup: keychainAccessGroup)
        self.credentials = credentials
        let cacheDefaults = defaults
        let audioCache = AudioCache(directory: paths.audioCacheDirectory) {
            Int64(max(0, MuurSettings.Snapshot.current(defaults: cacheDefaults).audioCacheLimitMB)) * 1_048_576
        }
        self.audioCache = audioCache
        let sources = SourceManager(repository: repository, credentials: credentials, paths: paths, cache: audioCache, defaults: defaults)
        self.sources = sources
        downloads = DownloadManager(sources: sources, paths: paths, defaults: defaults)
        discovery = SourceDiscovery()
        wifiTransfer = WiFiTransferServer(paths: paths, defaults: defaults)
    }

    /// Starts background services (called by `bootstrap`).
    public func start() {
        guard !started else { return }
        started = true
        wifiTransfer.onFilesReceived = { [weak self] files in
            guard let self else { return }
            Log.transfer.info("Received \(files.count) item(s) over Wi-Fi; rescanning")
            self.scanner.scan(folderID: "app-documents")
        }
        downloads.start()
        Task { [weak self] in
            guard let self else { return }
            await self.scanner.ensureDefaultFolder()
            self.scanner.scanAll()
            if self.settings.watchFolders {
                self.scanner.startMonitoring()
            }
        }
    }

    /// Handles a URL opened by the system (`onOpenURL`): OAuth redirects are consumed by the running web
    /// authentication session; audio, playlist and ZIP files are imported into the library.
    /// Returns true when the URL was handled.
    @discardableResult
    public func handleOpenURL(_ url: URL) async -> Bool {
        if OAuthManager.isOAuthRedirect(url) { return true }
        guard url.isFileURL else { return false }
        let name = url.lastPathComponent
        guard PathUtils.isAudio(name) || PathUtils.isPlaylist(name) || PathUtils.isArchive(name) else { return false }
        do {
            try await scanner.importFiles([url])
            return true
        } catch {
            Log.library.error("Import of opened file failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
