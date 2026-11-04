import Foundation
import GRDB

/// Creates, caches and resolves configured sources, and turns any track URI into a playable local file.
///
/// - Source instances are created lazily per configuration and reused until the configuration changes.
/// - Remote audio is downloaded into the LRU `AudioCache` (or served from completed offline downloads).
/// - Offline mode (`MuurSettings.offlineMode`) restricts playback to local files, downloads and cached audio.
///
/// Thread safety: all methods may be called from any context.
public final class SourceManager: @unchecked Sendable {
    public let repository: LibraryRepository
    public let credentials: CredentialStore
    public let paths: AppPaths
    public let cache: AudioCache
    private let defaults: UserDefaults
    private let instances = LockedValue<[UUID: (config: SourceConfig, source: any MusicSource)]>([:])
    private let archives = LockedValue<[String: ZipArchiveSource]>([:])
    private let prefetchTask = LockedValue<Task<Void, Never>?>(nil)

    public init(repository: LibraryRepository, credentials: CredentialStore, paths: AppPaths, cache: AudioCache,
                defaults: UserDefaults = .standard) {
        self.repository = repository
        self.credentials = credentials
        self.paths = paths
        self.cache = cache
        self.defaults = defaults
    }

    /// `true` while offline mode is enabled in the settings.
    public var isOffline: Bool { MuurSettings.Snapshot.current(defaults: defaults).offlineMode }

    // MARK: Factory

    /// Builds a source object for a configuration (no network access happens here).
    public static func makeSource(config: SourceConfig, secrets: SourceSecrets, credentials: CredentialStore,
                                  paths: AppPaths) throws -> any MusicSource {
        switch config.kind {
        case .local, .iCloud: return LocalSource(config: config, paths: paths)
        case .smb: return try SMBSource(config: config, secrets: secrets)
        case .webdav: return try WebDAVSource(config: config, secrets: secrets)
        case .ftp: return try FTPSource(config: config, secrets: secrets)
        case .sftp: return try SFTPSource(config: config, secrets: secrets)
        case .upnp: return try UPnPSource(config: config)
        case .s3: return try S3Source(config: config, secrets: secrets)
        case .dropbox: return try DropboxSource(config: config, secrets: secrets, credentials: credentials)
        case .googleDrive: return try GoogleDriveSource(config: config, secrets: secrets, credentials: credentials)
        case .oneDrive: return try OneDriveSource(config: config, secrets: secrets, credentials: credentials)
        case .box: return try BoxSource(config: config, secrets: secrets, credentials: credentials)
        case .pCloud: return try PCloudSource(config: config, secrets: secrets, credentials: credentials)
        case .subsonic: return try SubsonicSource(config: config, secrets: secrets)
        case .jellyfin, .emby: return try JellyfinSource(config: config, secrets: secrets, credentials: credentials)
        case .plex: return try PlexSource(config: config, secrets: secrets)
        }
    }

    // MARK: Configurations

    public func configs() async throws -> [SourceConfig] {
        try await repository.sources()
    }

    /// The live source object for a configuration (cached until the configuration changes).
    public func source(for config: SourceConfig) throws -> any MusicSource {
        if let existing = instances.get()[config.id], existing.config == config { return existing.source }
        let created = try SourceManager.makeSource(config: config, secrets: credentials.secrets(for: config.id),
                                                   credentials: credentials, paths: paths)
        let replaced = instances.mutate { map -> (any MusicSource)? in
            let old = map[config.id]?.source
            map[config.id] = (config, created)
            return old
        }
        if let replaced {
            Task { await replaced.disconnect() }
        }
        return created
    }

    public func source(id: UUID) async throws -> any MusicSource {
        if let existing = instances.get()[id] { return existing.source }
        guard let config = try await repository.source(id: id) else {
            throw MuurError.notFound("The source for this item (it may have been removed)")
        }
        return try source(for: config)
    }

    /// Saves a configuration (and its secrets, when given) and drops any cached instance.
    public func save(_ config: SourceConfig, secrets: SourceSecrets? = nil) async throws {
        if let secrets { try credentials.save(secrets, for: config.id) }
        try await repository.save(source: config)
        invalidate(config.id)
    }

    /// Verifies a configuration before saving it: connects and lists the root. Returns the root items.
    /// Secrets are stored under `config.id` first because some sources persist tokens while connecting.
    @discardableResult
    public func test(_ config: SourceConfig, secrets: SourceSecrets) async throws -> [SourceItem] {
        try credentials.save(secrets, for: config.id)
        let probe = try SourceManager.makeSource(config: config, secrets: secrets, credentials: credentials, paths: paths)
        do {
            try await probe.connect()
            let items = try await probe.list(nil)
            await probe.disconnect()
            return items
        } catch {
            await probe.disconnect()
            throw error
        }
    }

    /// Removes a source: configuration, library tracks, credentials, cached audio and (optionally) its offline downloads.
    public func remove(_ id: UUID, deleteDownloads: Bool = true) async throws {
        if let existing = instances.mutate({ $0.removeValue(forKey: id) }) {
            await existing.source.disconnect()
        }
        let key = id.uuidString
        let removedDownloads: [DownloadItem] = try await repository.database.write { db in
            let items = deleteDownloads
                ? try DownloadItem.fetchAll(db, sql: "SELECT * FROM downloads WHERE sourceID = ?", arguments: [key])
                : []
            if deleteDownloads {
                try db.execute(sql: "DELETE FROM downloads WHERE sourceID = ?", arguments: [key])
            }
            return items
        }
        let cachedURIs = try await repository.database.read { db in
            try String.fetchAll(db, sql: "SELECT sourceURI FROM tracks WHERE sourceID = ?", arguments: [key])
        }
        try await repository.deleteSource(id: id)
        credentials.remove(for: id)
        for uri in Set(cachedURIs) { await cache.remove(uri) }
        let fm = FileManager.default
        for item in removedDownloads {
            if let path = item.localPath { try? fm.removeItem(at: paths.downloadsDirectory.appendingPathComponent(path)) }
        }
        archives.mutate { map in
            map = map.filter { $0.value.config.id != id }
        }
    }

    /// Drops the cached instance of a source (call after editing credentials).
    public func invalidate(_ id: UUID) {
        if let existing = instances.mutate({ $0.removeValue(forKey: id) }) {
            Task { await existing.source.disconnect() }
        }
    }

    /// Disconnects every live source (e.g. when the app enters the background for a long time).
    public func disconnectAll() async {
        let all = instances.mutate { map -> [any MusicSource] in
            let values = map.values.map(\.source)
            map.removeAll()
            return values
        }
        for source in all { await source.disconnect() }
    }

    // MARK: URI resolution

    /// The source that owns `uri`. `sourceID` (from `Track.sourceID`) is preferred when present.
    public func source(forURI uri: String, sourceID: String? = nil) async throws -> any MusicSource {
        if let sourceID, let id = UUID(uuidString: sourceID) {
            return try await source(id: id)
        }
        guard let parsed = SourceURI.parse(uri) else { throw MuurError.invalidData("Invalid item URI") }
        if let components = parsed.zipComponents {
            return try await source(forURI: components.inner, sourceID: nil)
        }
        if let id = parsed.sourceID {
            return try await source(id: id)
        }
        if parsed.isFile {
            throw MuurError.unsupported("Resolving a source for local files")
        }
        let candidates = try await repository.sources().filter { SourceManager.owns($0, parsed) }
        let best = candidates.max { lhs, rhs in
            SourceManager.rootPath(lhs).count < SourceManager.rootPath(rhs).count
        }
        guard let best else {
            throw MuurError.notFound("A configured source for \(parsed.scheme)://\(parsed.authority)")
        }
        return try source(for: best)
    }

    /// Host part used by the URIs of a host-based source.
    static func uriAuthority(of config: SourceConfig) -> String {
        var host = config.host.trimmingCharacters(in: .whitespaces)
        if config.kind == .webdav, host.isEmpty,
           let preset = config.option(SourceConfig.OptionKey.webdavPreset).flatMap(WebDAVPreset.init(rawValue:)),
           let fixed = preset.fixedHost {
            host = fixed
        }
        if host.contains("://"), let parsedHost = URLComponents(string: host)?.host {
            return parsedHost.lowercased()
        }
        if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) }
        return host.lowercased()
    }

    /// Root path inside the server, used to pick the most specific of several sources on one host.
    static func rootPath(_ config: SourceConfig) -> String {
        if config.kind == .smb, let share = config.option(SourceConfig.OptionKey.smbShare) {
            let base = SourcePaths.root(config.basePath)
            return base == "/" ? "/" + share : "/" + share + base
        }
        return SourcePaths.root(config.basePath)
    }

    static func owns(_ config: SourceConfig, _ uri: SourceURI) -> Bool {
        let kindMatches: Bool
        switch uri.scheme {
        case "smb": kindMatches = config.kind == .smb
        case "sftp": kindMatches = config.kind == .sftp
        case "ftp", "ftps": kindMatches = config.kind == .ftp
        case "webdav", "webdavs": kindMatches = config.kind == .webdav
        default: kindMatches = false
        }
        guard kindMatches, uriAuthority(of: config) == uri.authority.lowercased() else { return false }
        if let port = uri.port, let configured = config.port, port != configured { return false }
        let root = rootPath(config)
        if config.kind == .ftp || config.kind == .sftp, !config.basePath.hasPrefix("/") {
            // Relative start folders depend on the server home directory and cannot be compared statically.
            return true
        }
        return root == "/" || uri.path == root || uri.path.hasPrefix(root + "/")
    }

    // MARK: Playback files

    /// A local file URL for a track (CUE tracks resolve to the shared audio file).
    public func playableURL(for track: Track, progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> URL {
        try await playableURL(forURI: track.sourceURI, sourceID: track.sourceID, fileName: track.fileName, progress: progress)
    }

    /// A local file URL for any source URI: local files are returned directly (iCloud placeholders are downloaded),
    /// remote files come from offline downloads, the audio cache, or are downloaded into the cache.
    public func playableURL(forURI uri: String, sourceID: String? = nil, fileName: String = "",
                            progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> URL {
        guard let parsed = SourceURI.parse(uri) else { throw MuurError.invalidData("Invalid item URI") }
        if parsed.isFile {
            return try await localFileURL(path: parsed.path)
        }
        if let downloaded = try await downloadedFileURL(for: uri) { return downloaded }
        if let cached = await cache.cachedURL(for: uri) { return cached }
        if let components = parsed.zipComponents {
            return try await zipEntryURL(uri: uri, inner: components.inner, entry: components.entry, sourceID: sourceID)
        }
        if isOffline { throw MuurError.offline }
        let source = try await source(forURI: uri, sourceID: sourceID)
        let name = fileName.isEmpty ? PathUtils.lastComponent(parsed.path) : fileName
        let report = progress ?? { _, _ in }
        return try await cache.file(for: uri, fileExtension: PathUtils.fileExtension(name)) { destination in
            try await source.download(uri: uri, to: destination, progress: report)
        }
    }

    /// `true` when the item can be played without network access.
    public func isAvailableOffline(_ track: Track) async -> Bool {
        if track.isLocal { return true }
        if (try? await downloadedFileURL(for: track.sourceURI)) != nil { return true }
        return await cache.contains(track.sourceURI)
    }

    /// The completed offline download of `uri`, if any.
    public func downloadedFileURL(for uri: String) async throws -> URL? {
        let item = try await repository.database.read { db in
            try DownloadItem.fetchOne(db, sql: "SELECT * FROM downloads WHERE sourceURI = ? AND state = ?",
                                      arguments: [uri, DownloadState.completed.rawValue])
        }
        guard let relative = item?.localPath else { return nil }
        let url = paths.downloadsDirectory.appendingPathComponent(relative)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func localFileURL(path: String) async throws -> URL {
        let stored = paths.resolveStoredFileURL(URL(fileURLWithPath: path))
        let url = try await UbiquityHelper.ensureDownloaded(stored)
        guard FileManager.default.fileExists(atPath: url.path) else { throw MuurError.notFound(url.lastPathComponent) }
        return url
    }

    private func zipEntryURL(uri: String, inner: String, entry: String, sourceID: String?) async throws -> URL {
        let archiveURL = try await localArchive(for: inner, sourceID: sourceID)
        return try await cache.file(for: uri, fileExtension: PathUtils.fileExtension(entry)) { destination in
            try ZipArchiveSource.extract(entry: entry, from: archiveURL, to: destination)
        }
    }

    /// A local copy of a ZIP archive identified by `uri` (local archives are used in place).
    public func localArchive(for uri: String, sourceID: String? = nil,
                             progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> URL {
        guard let parsed = SourceURI.parse(uri) else { throw MuurError.invalidData("Invalid archive URI") }
        if parsed.isFile { return try await localFileURL(path: parsed.path) }
        if parsed.isZip { return try await playableURL(forURI: uri, sourceID: sourceID, fileName: "archive.zip", progress: progress) }
        let target = paths.archiveExtractionDirectory.appendingPathComponent(String(Hashing.sha256Hex(uri).prefix(40)) + ".zip")
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) { return target }
        if isOffline { throw MuurError.offline }
        let source = try await source(forURI: uri, sourceID: sourceID)
        try fm.createDirectory(at: paths.archiveExtractionDirectory, withIntermediateDirectories: true)
        let partial = target.appendingPathExtension("partial")
        do {
            try await source.download(uri: uri, to: partial, progress: progress ?? { _, _ in })
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: partial, to: target)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        return target
    }

    /// A browsable source for a ZIP archive item found while browsing `parent` (nil for local archives).
    public func archiveSource(for item: SourceItem, in parent: (any MusicSource)? = nil,
                              progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> ZipArchiveSource {
        if let cached = archives.get()[item.uri] { return cached }
        let url = try await localArchive(for: item.uri, sourceID: parent?.config.id.uuidString, progress: progress)
        let archive = try ZipArchiveSource(archiveURL: url, archiveURI: item.uri, parent: parent?.config)
        archives.mutate { $0[item.uri] = archive }
        return archive
    }

    /// A direct HTTP resource for casting to DLNA renderers (nil for local files and sources without direct URLs).
    public func remoteResource(for track: Track) async throws -> RemoteResource? {
        guard let parsed = SourceURI.parse(track.sourceURI), !parsed.isFile, !parsed.isZip else { return nil }
        if isOffline { return nil }
        let source = try await source(forURI: track.sourceURI, sourceID: track.sourceID)
        guard source.capabilities.contains(.directURL) else { return nil }
        return try await source.streamURL(for: track.sourceURI)
    }

    /// Downloads the next tracks into the audio cache in the background (honours `prefetchNext` and offline mode).
    /// A new call cancels the previous prefetch run.
    public func prefetch(_ tracks: [Track]) {
        let settings = MuurSettings.Snapshot.current(defaults: defaults)
        let remote = tracks.filter { !$0.isLocal }
        guard settings.prefetchNext, !settings.offlineMode, !remote.isEmpty else { return }
        let task = Task.detached(priority: .utility) { [weak self] in
            for track in remote {
                if Task.isCancelled { return }
                guard let self else { return }
                do {
                    _ = try await self.playableURL(for: track)
                } catch {
                    Log.sources.info("Prefetch of \(track.displayTitle, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        prefetchTask.mutate { current in
            current?.cancel()
            current = task
        }
    }

    /// Protects the given URIs (current and upcoming queue items) from cache eviction.
    public func pinCached(_ uris: Set<String>) async {
        await cache.pin(uris)
    }

    // MARK: Library integration

    /// Imports the complete library of a media server (Subsonic, Jellyfin, Emby, Plex, DLNA) into the local
    /// database and removes tracks that disappeared from the server. Returns the number of tracks stored.
    @discardableResult
    public func syncLibrary(sourceID: UUID, progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> Int {
        if isOffline { throw MuurError.offline }
        let source = try await source(id: sourceID)
        guard let fetched = try await source.libraryTracks(progress: progress) else {
            throw MuurError.unsupported("Library import from \(source.config.kind.displayName)")
        }
        let key = sourceID.uuidString
        let tracks = fetched.map { track -> Track in
            var copy = track
            if copy.sourceID == nil { copy.sourceID = key }
            return copy
        }
        var keep = Set<Int64>()
        var start = 0
        while start < tracks.count {
            try Task.checkCancellation()
            let end = min(start + 1000, tracks.count)
            let stored = try await repository.upsert(Array(tracks[start..<end]))
            for track in stored { if let id = track.id { keep.insert(id) } }
            start = end
        }
        let keepIDs = keep
        try await repository.database.write { db in
            let existing = try Int64.fetchAll(db, sql: "SELECT id FROM tracks WHERE sourceID = ?", arguments: [key])
            let stale = existing.filter { !keepIDs.contains($0) }
            var offset = 0
            while offset < stale.count {
                let chunk = Array(stale[offset..<min(offset + 500, stale.count)])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                try db.execute(sql: "DELETE FROM tracks WHERE id IN (\(placeholders))", arguments: StatementArguments(chunk))
                offset += chunk.count
            }
        }
        return tracks.count
    }

    /// Adds browsed items (files and whole folders) of a source to the library. Local and iCloud files are read
    /// with full tag metadata; remote files are added with metadata derived from the file name (media server items
    /// carry server metadata). Returns the stored tracks.
    @discardableResult
    public func addToLibrary(_ items: [SourceItem], from source: any MusicSource,
                             progress: @escaping @Sendable (Int) -> Void = { _ in }) async throws -> [Track] {
        var audio: [SourceItem] = []
        for item in items {
            try Task.checkCancellation()
            if item.kind == .audio {
                audio.append(item)
            } else if item.kind == .folder {
                audio.append(contentsOf: try await source.collectAudio(under: item))
            }
            progress(audio.count)
        }
        var tracks: [Track] = []
        tracks.reserveCapacity(audio.count)
        let isLocal = source.config.kind == .local || source.config.kind == .iCloud
        for item in audio {
            try Task.checkCancellation()
            var track = source.makeTrack(for: item, folderPath: SourceManager.displayFolder(of: item, in: source.config))
            if isLocal {
                track.sourceID = nil
                let url = URL(fileURLWithPath: item.path)
                if !UbiquityHelper.needsDownload(url), let metadata = await MetadataReader.read(url: url) {
                    metadata.apply(to: &track)
                }
            }
            tracks.append(track)
        }
        var stored: [Track] = []
        var start = 0
        while start < tracks.count {
            let end = min(start + 1000, tracks.count)
            stored.append(contentsOf: try await repository.upsert(Array(tracks[start..<end])))
            start = end
        }
        return stored
    }

    static func displayFolder(of item: SourceItem, in config: SourceConfig) -> String {
        if let track = item.track, !track.folderPath.isEmpty { return track.folderPath }
        let parent = PathUtils.parent(item.path.hasPrefix("/") ? item.path : "/" + item.path)
        if config.kind == .local || config.kind == .iCloud {
            return parent
        }
        return parent == "/" || parent.isEmpty ? config.name : config.name + parent
    }
}
