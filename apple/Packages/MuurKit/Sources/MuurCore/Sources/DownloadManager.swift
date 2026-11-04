import Foundation
import Network
import GRDB

/// Delegate of the background `URLSession` used for offline downloads of direct HTTP resources.
/// Files are moved into the downloads folder inside `didFinishDownloadingTo` (the system deletes the
/// temporary file afterwards), then the result is reported through `Handlers`.
final class BackgroundDownloadSession: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct TaskInfo: Codable {
        var id: String
        /// Destination path relative to the downloads folder, without extension.
        var stem: String
        /// Extension hint from the URI ("" when unknown; detected from content).
        var ext: String
    }

    struct Finished: Sendable {
        var relativePath: String
        var bytes: Int64
    }

    struct Handlers: Sendable {
        var progress: @Sendable (String, Int64, Int64) -> Void
        var completion: @Sendable (String, Result<Finished, Error>, Data?) -> Void
        var eventsFinished: @Sendable () -> Void
    }

    let downloadsDirectory: URL
    /// Hosts whose self-signed certificates are accepted (sources with `allowInsecureTLS`).
    let insecureHosts = LockedValue<Set<String>>([])
    private let handlers: Handlers
    private let finished = LockedValue<[Int: Result<Finished, Error>]>([:])
    private(set) var session: URLSession!

    init(identifier: String, downloadsDirectory: URL, handlers: Handlers) {
        self.downloadsDirectory = downloadsDirectory
        self.handlers = handlers
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.httpAdditionalHeaders = ["User-Agent": HTTPClient.userAgent]
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    static func info(of task: URLSessionTask) -> TaskInfo? {
        guard let text = task.taskDescription, let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TaskInfo.self, from: data)
    }

    static func describe(_ info: TaskInfo) -> String {
        guard let data = try? JSONEncoder().encode(info) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           insecureHosts.get().contains(space.host.lowercased()), let trust = space.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let info = BackgroundDownloadSession.info(of: downloadTask) else { return }
        handlers.progress(info.id, totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let info = BackgroundDownloadSession.info(of: downloadTask) else { return }
        let identifier = downloadTask.taskIdentifier
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let error: MuurError = http.statusCode == 401 || http.statusCode == 403
                ? .authenticationFailed("HTTP \(http.statusCode)")
                : .http(status: http.statusCode, message: "")
            finished.mutate { $0[identifier] = .failure(error) }
            return
        }
        do {
            var ext = info.ext.lowercased()
            if !PathUtils.audioExtensions.contains(ext) {
                ext = AudioFormatSniffer.fileExtension(of: location) ?? (ext.isEmpty ? "audio" : ext)
            }
            let relative = info.stem + "." + ext
            let target = downloadsDirectory.appendingPathComponent(relative)
            let fm = FileManager.default
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: location, to: target)
            let size = ((try? fm.attributesOfItem(atPath: target.path))?[.size] as? NSNumber)?.int64Value ?? 0
            finished.mutate { $0[identifier] = .success(Finished(relativePath: relative, bytes: size)) }
        } catch {
            finished.mutate { $0[identifier] = .failure(MuurError.io(error.localizedDescription)) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let info = BackgroundDownloadSession.info(of: task) else { return }
        let stored = finished.mutate { $0.removeValue(forKey: task.taskIdentifier) }
        if let error {
            let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            let mapped: Error = (error as? URLError)?.code == .cancelled
                ? MuurError.cancelled
                : MuurError.network(error.localizedDescription)
            handlers.completion(info.id, .failure(mapped), resumeData)
            return
        }
        if let stored {
            handlers.completion(info.id, stored, nil)
            return
        }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        handlers.completion(info.id, .failure(MuurError.http(status: status, message: "")), nil)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        handlers.eventsFinished()
    }
}

/// Offline downloads of remote tracks (FEATURES "Offline mode").
///
/// Downloads are persisted in the `downloads` table and survive relaunches. Direct HTTP resources
/// (DLNA, S3, WebDAV without password, Subsonic, Jellyfin/Emby, Plex) use a background `URLSession`
/// so they continue while the app is suspended; other sources (SMB, SFTP, FTP, cloud drives, ZIP entries)
/// download in-process. Failed downloads are retried automatically with exponential back-off.
/// Completed files live in `AppPaths.downloadsDirectory`; `SourceManager.playableURL` prefers them.
///
/// Main-actor observable: bind `items` and `isWaitingForWiFi` to the UI. Call `start()` once at launch.
@MainActor
public final class DownloadManager: ObservableObject {
    public static let backgroundSessionIdentifier = "app.muur.music.downloads"
    public static let maxAutomaticRetries = 3

    /// All downloads, newest first.
    @Published public private(set) var items: [DownloadItem] = []
    /// `true` while queued downloads wait because the network is cellular and cellular downloads are disabled.
    @Published public private(set) var isWaitingForWiFi = false
    @Published public var maxConcurrentDownloads: Int = 2 {
        didSet { pump() }
    }

    public let sources: SourceManager
    private let database: MuurDatabase
    private let paths: AppPaths
    private let defaults: UserDefaults
    private var background: BackgroundDownloadSession?
    private var foregroundTasks: [String: Task<Void, Never>] = [:]
    private var backgroundTasks: [String: URLSessionDownloadTask] = [:]
    private var starting: Set<String> = []
    private var pauseRequested: Set<String> = []
    private var removeRequested: Set<String> = []
    private var retryNotBefore: [String: Date] = [:]
    private var lastProgressWrite: [String: Date] = [:]
    private var observationTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var pathIsExpensive = false
    private var backgroundEventsCompletion: (() -> Void)?
    private var defaultsObserver: NSObjectProtocol?
    private var started = false
    private var reconciled = false

    public init(sources: SourceManager, paths: AppPaths, defaults: UserDefaults = .standard) {
        self.sources = sources
        self.database = sources.repository.database
        self.paths = paths
        self.defaults = defaults
    }

    // MARK: Lifecycle

    /// Connects the background session (picking up transfers that ran while the app was not running),
    /// starts observing the downloads table and begins processing the queue.
    public func start() {
        guard !started else { return }
        started = true
        let handlers = BackgroundDownloadSession.Handlers(
            progress: { [weak self] id, received, expected in
                Task { @MainActor in self?.recordProgress(id: id, received: received, expected: expected) }
            },
            completion: { [weak self] id, result, resumeData in
                Task { @MainActor in await self?.backgroundTaskFinished(id: id, result: result, resumeData: resumeData) }
            },
            eventsFinished: { [weak self] in
                Task { @MainActor in self?.finishBackgroundEvents() }
            })
        background = BackgroundDownloadSession(identifier: DownloadManager.backgroundSessionIdentifier,
                                               downloadsDirectory: paths.downloadsDirectory, handlers: handlers)
        startPathMonitor()
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults,
                                                                  queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pump() }
        }
        let observation = database.observe { db in try LibraryQueries.downloads(db) }
        observationTask = Task { [weak self] in
            do {
                for try await value in observation {
                    guard let self else { return }
                    self.items = value
                    self.pump()
                }
            } catch {
                Log.downloads.error("Download observation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        Task { [weak self] in await self?.reconcile() }
    }

    /// Call from `application(_:handleEventsForBackgroundURLSession:completionHandler:)` (iOS).
    /// Returns false when the identifier does not belong to MuurKit.
    @discardableResult
    public func handleBackgroundEvents(identifier: String, completionHandler: @escaping () -> Void) -> Bool {
        guard identifier == DownloadManager.backgroundSessionIdentifier else { return false }
        backgroundEventsCompletion = completionHandler
        start()
        return true
    }

    private func finishBackgroundEvents() {
        let completion = backgroundEventsCompletion
        backgroundEventsCompletion = nil
        completion?()
    }

    private func reconcile() async {
        var live: [String: URLSessionDownloadTask] = [:]
        if let session = background?.session {
            let tasks = await session.allTasks
            for task in tasks {
                guard let download = task as? URLSessionDownloadTask, let info = BackgroundDownloadSession.info(of: task),
                      task.state == .running || task.state == .suspended else { continue }
                live[info.id] = download
            }
        }
        for (id, task) in live where backgroundTasks[id] == nil {
            backgroundTasks[id] = task
        }
        let liveIDs = Set(live.keys)
        do {
            try await database.write { db in
                let stale = try DownloadItem.fetchAll(db, sql: "SELECT * FROM downloads WHERE state = ?",
                                                      arguments: [DownloadState.downloading.rawValue])
                for var item in stale where !liveIDs.contains(item.id) {
                    item.state = .queued
                    item.updatedAt = Date()
                    try item.update(db)
                }
            }
            let configs = try await sources.configs()
            let insecure = Set(configs.filter(\.allowInsecureTLS).map { SourceManager.uriAuthority(of: $0) })
            background?.insecureHosts.mutate { $0.formUnion(insecure) }
        } catch {
            Log.downloads.error("Reconciling downloads failed: \(error.localizedDescription, privacy: .public)")
        }
        reconciled = true
        pump()
    }

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive
            Task { @MainActor in
                self?.pathIsExpensive = expensive
                self?.pump()
            }
        }
        monitor.start(queue: DispatchQueue(label: "app.muur.downloads.path"))
        pathMonitor = monitor
    }

    // MARK: Queries

    public func item(for uri: String) -> DownloadItem? {
        items.first { $0.sourceURI == uri }
    }

    /// The downloaded file for a source URI.
    public func localURL(for uri: String) -> URL? {
        guard let item = item(for: uri), item.state == .completed, let relative = item.localPath else { return nil }
        let url = paths.downloadsDirectory.appendingPathComponent(relative)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func isDownloaded(_ track: Track) -> Bool {
        item(for: track.sourceURI)?.state == .completed
    }

    public var activeCount: Int { items.filter { $0.state == .downloading || $0.state == .queued }.count }

    /// Total size of completed downloads.
    public var totalDownloadedBytes: Int64 {
        items.filter { $0.state == .completed }.reduce(0) { $0 + $1.bytesReceived }
    }

    // MARK: Queue management

    /// Queues remote tracks for offline download (local files are skipped; CUE tracks share one file).
    /// Returns the number of newly queued or re-queued downloads.
    @discardableResult
    public func enqueue(_ tracks: [Track], groupName: String? = nil) async throws -> Int {
        let remote = tracks.filter { !$0.isLocal && !$0.sourceURI.hasPrefix("zip://file:") }
        guard !remote.isEmpty else { return 0 }
        let added = try await database.write { db -> Int in
            var count = 0
            var seen = Set<String>()
            for track in remote where seen.insert(track.sourceURI).inserted {
                if var existing = try DownloadItem.fetchOne(db, sql: "SELECT * FROM downloads WHERE sourceURI = ?", arguments: [track.sourceURI]) {
                    if existing.state == .failed || existing.state == .paused {
                        existing.state = .queued
                        existing.retryCount = 0
                        existing.errorMessage = nil
                        existing.updatedAt = Date()
                        try existing.update(db)
                        count += 1
                    }
                    continue
                }
                let item = DownloadItem(sourceURI: track.sourceURI, sourceID: track.sourceID,
                                        title: track.isCueTrack ? (track.album.isEmpty ? track.fileName : track.album) : track.displayTitle,
                                        artist: track.displayArtist, album: track.album, groupName: groupName, trackId: track.id)
                try item.insert(db)
                count += 1
            }
            return count
        }
        pump()
        return added
    }

    public func pause(_ id: String) async {
        if let task = foregroundTasks[id] {
            pauseRequested.insert(id)
            task.cancel()
            return
        }
        if let task = backgroundTasks[id] {
            pauseRequested.insert(id)
            if let data = await task.cancelByProducingResumeData() {
                try? FileManager.default.createDirectory(at: paths.resumeDataDirectory, withIntermediateDirectories: true)
                try? data.write(to: resumeDataURL(id))
            }
            return
        }
        await update(id) { item in
            if item.state == .queued || item.state == .downloading { item.state = .paused }
        }
    }

    public func resume(_ id: String) async {
        await update(id) { item in
            if item.state == .paused || item.state == .failed {
                item.state = .queued
                item.errorMessage = nil
            }
        }
        pump()
    }

    /// Re-queues a failed download with a fresh retry budget.
    public func retry(_ id: String) async {
        retryNotBefore[id] = nil
        await update(id) { item in
            item.state = .queued
            item.retryCount = 0
            item.errorMessage = nil
        }
        pump()
    }

    /// Cancels and deletes a download (including the downloaded file).
    public func remove(_ id: String) async {
        let item = items.first { $0.id == id }
        if let task = foregroundTasks[id] {
            removeRequested.insert(id)
            task.cancel()
        }
        if let task = backgroundTasks[id] {
            removeRequested.insert(id)
            task.cancel()
        }
        try? FileManager.default.removeItem(at: resumeDataURL(id))
        if let relative = item?.localPath {
            try? FileManager.default.removeItem(at: paths.downloadsDirectory.appendingPathComponent(relative))
        }
        do {
            try await database.write { db in
                try db.execute(sql: "DELETE FROM downloads WHERE id = ?", arguments: [id])
            }
        } catch {
            Log.downloads.error("Removing download failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Removes the download of a track, if any.
    public func removeDownload(for track: Track) async {
        if let item = item(for: track.sourceURI) { await remove(item.id) }
    }

    public func pauseAll() async {
        for item in items where item.state == .queued || item.state == .downloading {
            await pause(item.id)
        }
    }

    public func resumeAll() async {
        for item in items where item.state == .paused || item.state == .failed {
            await resume(item.id)
        }
    }

    public func removeAll(in states: Set<DownloadState> = Set(DownloadState.allCases)) async {
        for item in items where states.contains(item.state) {
            await remove(item.id)
        }
    }

    // MARK: Processing

    /// Starts queued downloads up to `maxConcurrentDownloads`. Called automatically on changes.
    public func pump() {
        guard started, reconciled else { return }
        let settings = MuurSettings.Snapshot.current(defaults: defaults)
        let hasQueued = items.contains { $0.state == .queued }
        if settings.offlineMode {
            isWaitingForWiFi = false
            return
        }
        let blockedByCellular = pathIsExpensive && !settings.downloadOverCellular
        isWaitingForWiFi = blockedByCellular && hasQueued
        guard !blockedByCellular, hasQueued else { return }
        let busy = Set(foregroundTasks.keys).union(backgroundTasks.keys).union(starting)
        var free = maxConcurrentDownloads - busy.count
        let now = Date()
        for item in items.reversed() where free > 0 && item.state == .queued && !busy.contains(item.id) {
            if let notBefore = retryNotBefore[item.id], notBefore > now { continue }
            free -= 1
            begin(item)
        }
    }

    private func begin(_ item: DownloadItem) {
        starting.insert(item.id)
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.run(item)
        }
        foregroundTasks[item.id] = task
    }

    private func resumeDataURL(_ id: String) -> URL {
        paths.resumeDataDirectory.appendingPathComponent(id + ".resume")
    }

    static func fileStem(for item: DownloadItem) -> String {
        let label = item.artist.isEmpty ? item.title : "\(item.artist) - \(item.title)"
        let safe = String(PathUtils.sanitizeFileName(label).prefix(80))
        return safe + " [" + String(Hashing.sha256Hex(item.sourceURI).prefix(8)) + "]"
    }

    /// Kinds whose `streamURL` is a stable, original-quality HTTP resource suitable for background transfer.
    static func supportsBackgroundTransfer(_ kind: SourceKind) -> Bool {
        switch kind {
        case .upnp, .s3, .webdav, .subsonic, .jellyfin, .emby, .plex: return true
        default: return false
        }
    }

    private func run(_ item: DownloadItem) async {
        let id = item.id
        defer {
            starting.remove(id)
            foregroundTasks[id] = nil
        }
        await update(id) { current in
            current.state = .downloading
            current.errorMessage = nil
        }
        do {
            let uri = item.sourceURI
            let parsed = SourceURI.parse(uri)
            let entryName: String
            if let zip = parsed?.zipComponents {
                entryName = PathUtils.lastComponent(zip.entry)
            } else {
                entryName = PathUtils.lastComponent(parsed?.path ?? uri)
            }
            let extHint = PathUtils.fileExtension(entryName)
            let stem = (item.sourceID ?? "other") + "/" + DownloadManager.fileStem(for: item)
            let fm = FileManager.default

            if let cached = await sources.cache.cachedURL(for: uri) {
                let relative = stem + "." + cached.pathExtension
                let target = paths.downloadsDirectory.appendingPathComponent(relative)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.copyItem(at: cached, to: target)
                await complete(id, relativePath: relative, bytes: DownloadManager.fileSize(target))
                return
            }
            if parsed?.isZip == true {
                let extracted = try await sources.playableURL(forURI: uri, sourceID: item.sourceID, fileName: entryName)
                let relative = stem + "." + extracted.pathExtension
                let target = paths.downloadsDirectory.appendingPathComponent(relative)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.copyItem(at: extracted, to: target)
                await complete(id, relativePath: relative, bytes: DownloadManager.fileSize(target))
                return
            }

            let source = try await sources.source(forURI: uri, sourceID: item.sourceID)
            try Task.checkCancellation()
            if let background, DownloadManager.supportsBackgroundTransfer(source.config.kind),
               source.capabilities.contains(.directURL), let resource = try await source.streamURL(for: uri) {
                startBackgroundTransfer(id: id, resource: resource, stem: stem, ext: extHint,
                                        insecure: source.config.allowInsecureTLS, session: background)
                return
            }

            let partialDirectory = paths.downloadsDirectory.appendingPathComponent(".partial", isDirectory: true)
            try fm.createDirectory(at: partialDirectory, withIntermediateDirectories: true)
            let partial = partialDirectory.appendingPathComponent(id + ".partial")
            do {
                try await source.download(uri: uri, to: partial) { [weak self] received, expected in
                    Task { @MainActor in self?.recordProgress(id: id, received: received, expected: expected) }
                }
                try Task.checkCancellation()
            } catch {
                try? fm.removeItem(at: partial)
                throw error
            }
            var ext = extHint
            if !PathUtils.audioExtensions.contains(ext) {
                ext = AudioFormatSniffer.fileExtension(of: partial) ?? (ext.isEmpty ? "audio" : ext)
            }
            let relative = stem + "." + ext
            let target = paths.downloadsDirectory.appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: partial, to: target)
            await complete(id, relativePath: relative, bytes: DownloadManager.fileSize(target))
        } catch {
            await handleFailure(id: id, error: error)
        }
    }

    private func startBackgroundTransfer(id: String, resource: RemoteResource, stem: String, ext: String, insecure: Bool,
                                         session background: BackgroundDownloadSession) {
        var request = URLRequest(url: resource.url)
        for (key, value) in resource.headers { request.setValue(value, forHTTPHeaderField: key) }
        request.allowsCellularAccess = MuurSettings.Snapshot.current(defaults: defaults).downloadOverCellular
        if insecure, let host = resource.url.host {
            background.insecureHosts.mutate { $0.insert(host.lowercased()) }
        }
        let resumeURL = resumeDataURL(id)
        let task: URLSessionDownloadTask
        if let data = try? Data(contentsOf: resumeURL) {
            task = background.session.downloadTask(withResumeData: data)
            try? FileManager.default.removeItem(at: resumeURL)
        } else {
            task = background.session.downloadTask(with: request)
        }
        task.taskDescription = BackgroundDownloadSession.describe(.init(id: id, stem: stem, ext: ext))
        backgroundTasks[id] = task
        task.resume()
    }

    private func backgroundTaskFinished(id: String, result: Result<BackgroundDownloadSession.Finished, Error>, resumeData: Data?) async {
        backgroundTasks[id] = nil
        switch result {
        case .success(let finished):
            await complete(id, relativePath: finished.relativePath, bytes: finished.bytes)
        case .failure(let error):
            if let resumeData {
                try? FileManager.default.createDirectory(at: paths.resumeDataDirectory, withIntermediateDirectories: true)
                try? resumeData.write(to: resumeDataURL(id))
            }
            await handleFailure(id: id, error: error)
        }
        pump()
    }

    private func recordProgress(id: String, received: Int64, expected: Int64) {
        let now = Date()
        if let last = lastProgressWrite[id], now.timeIntervalSince(last) < 0.5 { return }
        lastProgressWrite[id] = now
        Task {
            await update(id) { item in
                guard item.state == .downloading else { return }
                item.bytesReceived = received
                item.bytesExpected = max(expected, 0)
                item.progress = expected > 0 ? min(1, Double(received) / Double(expected)) : 0
            }
        }
    }

    private func complete(_ id: String, relativePath: String, bytes: Int64) async {
        lastProgressWrite[id] = nil
        retryNotBefore[id] = nil
        let exists: Bool
        do {
            exists = try await database.write { db -> Bool in
                guard var item = try DownloadItem.fetchOne(db, key: id) else { return false }
                item.state = .completed
                item.localPath = relativePath
                item.progress = 1
                item.bytesReceived = bytes
                item.bytesExpected = bytes
                item.errorMessage = nil
                item.updatedAt = Date()
                try item.update(db)
                return true
            }
        } catch {
            Log.downloads.error("Saving download failed: \(error.localizedDescription, privacy: .public)")
            exists = true
        }
        if !exists || removeRequested.remove(id) != nil {
            // The download was removed while transferring.
            try? FileManager.default.removeItem(at: paths.downloadsDirectory.appendingPathComponent(relativePath))
        }
        Log.downloads.info("Download finished: \(relativePath, privacy: .public)")
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if let muur = error as? MuurError {
            switch muur {
            case .network, .io: return true
            case .http(let status, _): return status >= 500 || status == 408 || status == 429
            default: return false
            }
        }
        return error is URLError
    }

    private func handleFailure(id: String, error: Error) async {
        lastProgressWrite[id] = nil
        if removeRequested.remove(id) != nil { return }
        if pauseRequested.remove(id) != nil {
            await update(id) { $0.state = .paused }
            return
        }
        if error is CancellationError || (error as? MuurError) == .cancelled {
            await update(id) { $0.state = .paused }
            return
        }
        if (error as? MuurError) == .offline {
            await update(id) { $0.state = .queued }
            return
        }
        let message = error.localizedDescription
        let previous = items.first { $0.id == id }?.retryCount ?? 0
        let attempts = previous + 1
        Log.downloads.error("Download \(id, privacy: .public) failed (attempt \(attempts)): \(message, privacy: .public)")
        if DownloadManager.isRetryable(error) && attempts < DownloadManager.maxAutomaticRetries {
            let delay = 5 * pow(2, Double(attempts))
            retryNotBefore[id] = Date().addingTimeInterval(delay)
            await update(id) { item in
                item.state = .queued
                item.retryCount = attempts
                item.errorMessage = message
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                self?.retryNotBefore[id] = nil
                self?.pump()
            }
        } else {
            await update(id) { item in
                item.state = .failed
                item.retryCount = attempts
                item.errorMessage = message
            }
        }
    }

    private func update(_ id: String, _ body: @escaping @Sendable (inout DownloadItem) -> Void) async {
        do {
            try await database.write { db in
                guard var item = try DownloadItem.fetchOne(db, key: id) else { return }
                body(&item)
                item.updatedAt = Date()
                try item.update(db)
            }
        } catch {
            Log.downloads.error("Updating download failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
