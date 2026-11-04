import Foundation
import GRDB
import ZIPFoundation

/// Progress of a library scan.
public struct ScanProgress: Sendable, Equatable {
    public enum Phase: String, Sendable { case idle, enumerating, reading, saving, finished }

    public var phase: Phase
    public var folderName: String
    public var processed: Int
    public var total: Int
    public var currentItem: String

    public init(phase: Phase = .idle, folderName: String = "", processed: Int = 0, total: Int = 0, currentItem: String = "") {
        self.phase = phase
        self.folderName = folderName
        self.processed = processed
        self.total = total
        self.currentItem = currentItem
    }

    public var fraction: Double { total > 0 ? min(1, Double(processed) / Double(total)) : 0 }
}

/// Result of scanning one folder.
public struct ScanSummary: Sendable, Equatable {
    public var folderName: String
    public var added: Int
    public var updated: Int
    public var unchanged: Int
    public var removed: Int
    public var failed: Int

    public init(folderName: String, added: Int = 0, updated: Int = 0, unchanged: Int = 0, removed: Int = 0, failed: Int = 0) {
        self.folderName = folderName
        self.added = added
        self.updated = updated
        self.unchanged = unchanged
        self.removed = removed
        self.failed = failed
    }
}

/// Performs folder scans off the main actor.
final class LibraryScanEngine: Sendable {
    struct FileInfo: Sendable {
        var url: URL
        var size: Int64
        var modified: Date?
        var isPlaceholder: Bool
    }

    struct DirectoryListing: Sendable {
        var url: URL
        var audio: [FileInfo] = []
        var cues: [FileInfo] = []
        var lyricsBaseNames: Set<String> = []
        var images: [URL] = []
    }

    enum Job: Sendable {
        case file(FileInfo, directory: DirectoryListing)
        case cue(cue: FileInfo, sheet: CueSheet, sheetFileName: String, audio: FileInfo, directory: DirectoryListing)
    }

    let database: MuurDatabase
    let artwork: ArtworkCache
    let paths: AppPaths
    private let folderArtwork = LockedValue<[String: String?]>([:])

    init(database: MuurDatabase, artwork: ArtworkCache, paths: AppPaths) {
        self.database = database
        self.artwork = artwork
        self.paths = paths
    }

    /// The default library folder: the app's Documents folder on iOS (Files app / Wi-Fi transfer),
    /// `~/Music/MuurMusic` on macOS.
    var defaultFolderURL: URL {
        #if os(macOS)
        return paths.musicFolder
        #else
        return paths.documents
        #endif
    }

    func rootURL(for folder: WatchedFolder) async throws -> URL {
        if folder.isAppDocuments {
            try? FileManager.default.createDirectory(at: defaultFolderURL, withIntermediateDirectories: true)
            return defaultFolderURL
        }
        guard let bookmark = folder.bookmark else { return URL(fileURLWithPath: folder.path, isDirectory: true) }
        let resolved = try SecurityScopeManager.shared.resolve(bookmark: bookmark)
        let url = try SecurityScopeManager.shared.startAccessing(bookmark: bookmark, key: "folder:" + folder.id)
        if resolved.isStale, let fresh = try? SecurityScopeManager.shared.makeBookmark(for: url) {
            var updated = folder
            updated.bookmark = fresh
            let record = updated
            try await database.write { db in try record.save(db) }
        }
        return url
    }

    static func directoryPrefix(_ url: URL) -> String {
        let uri = SourceURI.file(URL(fileURLWithPath: url.path, isDirectory: true))
        return uri.hasSuffix("/") ? uri : uri + "/"
    }

    /// Rewrites stored URIs after the folder moved (e.g. iOS container path changes on app updates).
    static func relocate(_ db: Database, from oldPrefix: String, to newPrefix: String) throws {
        guard oldPrefix != newPrefix else { return }
        let pattern = LibraryQueries.likeEscape(oldPrefix) + "%"
        let length = oldPrefix.count
        try db.execute(sql: """
            UPDATE OR IGNORE tracks SET
                sourceURI = ?1 || substr(sourceURI, ?2 + 1),
                libraryKey = ?1 || substr(libraryKey, ?2 + 1),
                cueSheetURI = CASE WHEN cueSheetURI LIKE ?3 ESCAPE '\\' THEN ?1 || substr(cueSheetURI, ?2 + 1) ELSE cueSheetURI END
            WHERE sourceURI LIKE ?3 ESCAPE '\\'
            """, arguments: [newPrefix, length, pattern])
        for table in ["playlist_items", "bookmarks", "play_history"] {
            try db.execute(sql: """
                UPDATE \(table) SET sourceURI = ?1 || substr(sourceURI, ?2 + 1), libraryKey = ?1 || substr(libraryKey, ?2 + 1)
                WHERE sourceURI LIKE ?3 ESCAPE '\\'
                """, arguments: [newPrefix, length, pattern])
        }
    }

    // MARK: Enumeration

    func enumerate(root: URL) -> [DirectoryListing] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsPackageDescendants],
                                                              errorHandler: { _, _ in true }) else { return [] }
        var listings: [String: DirectoryListing] = [:]
        while let next = enumerator.nextObject() {
            guard let url = next as? URL else { continue }
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if name.hasPrefix(".") || name == "Inbox" && url.deletingLastPathComponent().path == root.path {
                    enumerator.skipDescendants()
                }
                continue
            }
            var fileURL = url
            var placeholder = false
            if name.hasPrefix(".") {
                guard name.hasSuffix(".icloud") else { continue }
                fileURL = UbiquityHelper.resolvePlaceholder(url)
                placeholder = true
            }
            let realName = fileURL.lastPathComponent
            let ext = PathUtils.fileExtension(realName)
            let directory = fileURL.deletingLastPathComponent()
            let info = FileInfo(url: fileURL, size: Int64(values?.fileSize ?? 0), modified: values?.contentModificationDate,
                                isPlaceholder: placeholder)
            var listing = listings[directory.path] ?? DirectoryListing(url: directory)
            if PathUtils.isAudio(realName) {
                listing.audio.append(info)
            } else if ext == "cue" {
                listing.cues.append(info)
            } else if ext == "lrc" {
                listing.lyricsBaseNames.insert((realName as NSString).deletingPathExtension.lowercased())
            } else if PathUtils.imageExtensions.contains(ext) && !placeholder {
                listing.images.append(fileURL)
            } else {
                continue
            }
            listings[directory.path] = listing
        }
        return Array(listings.values)
    }

    func folderPath(for directory: URL, root: URL, folderName: String) -> String {
        let rootPath = root.standardizedFileURL.path
        let dirPath = directory.standardizedFileURL.path
        guard dirPath.hasPrefix(rootPath) else { return folderName }
        var relative = String(dirPath.dropFirst(rootPath.count))
        while relative.hasPrefix("/") { relative.removeFirst() }
        while relative.hasSuffix("/") { relative.removeLast() }
        return relative.isEmpty ? folderName : folderName + "/" + relative
    }

    /// Artwork key for the best image in a directory (cover/folder/front first), cached per scan.
    func directoryArtworkKey(_ listing: DirectoryListing) -> String? {
        if let cached = folderArtwork.get()[listing.url.path] { return cached }
        let preferred = ["cover", "folder", "front", "album", "albumart", "albumartlarge", "artwork"]
        let sorted = listing.images.sorted { lhs, rhs in
            func rank(_ url: URL) -> Int {
                let base = url.deletingPathExtension().lastPathComponent.lowercased()
                if let index = preferred.firstIndex(of: base) { return index }
                if preferred.contains(where: { base.hasPrefix($0) }) { return preferred.count }
                return preferred.count + 1
            }
            return rank(lhs) < rank(rhs)
        }
        let key = sorted.first.flatMap { artwork.store(contentsOf: $0) }
        folderArtwork.mutate { $0[listing.url.path] = .some(key) }
        return key
    }

    // MARK: Scanning

    func scan(folder: WatchedFolder, full: Bool, progress: @escaping @Sendable (ScanProgress) -> Void) async throws -> ScanSummary {
        folderArtwork.set([:])
        var summary = ScanSummary(folderName: folder.name)
        progress(ScanProgress(phase: .enumerating, folderName: folder.name))
        let root = try await rootURL(for: folder)
        let rootPrefix = LibraryScanEngine.directoryPrefix(root)

        if !folder.path.isEmpty && folder.path != root.path {
            let oldPrefix = LibraryScanEngine.directoryPrefix(URL(fileURLWithPath: folder.path, isDirectory: true))
            try await database.write { db in try LibraryScanEngine.relocate(db, from: oldPrefix, to: rootPrefix) }
        }

        let listings = enumerate(root: root)
        let existingRows: [String: (Double?, Int64)] = try await database.read { db in
            var result: [String: (Double?, Int64)] = [:]
            let rows = try Row.fetchAll(db, sql: "SELECT libraryKey, fileModified, fileSize FROM tracks WHERE libraryKey LIKE ? ESCAPE '\\'",
                                        arguments: [LibraryQueries.likeEscape(rootPrefix) + "%"])
            for row in rows {
                let key: String = row["libraryKey"]
                result[key] = (row["fileModified"], row["fileSize"] ?? 0)
            }
            return result
        }

        var jobs: [Job] = []
        var keep = Set<String>()
        for listing in listings {
            var covered = Set<String>()
            for cue in listing.cues where !cue.isPlaceholder {
                guard let data = try? Data(contentsOf: cue.url) else { continue }
                let sheet = CueSheet.parse(data: data)
                for sheetFile in sheet.files {
                    guard let audio = LibraryScanEngine.matchCueAudio(sheetFile, in: listing) else { continue }
                    covered.insert(audio.url.path)
                    let audioURI = SourceURI.file(audio.url)
                    let modified = max(audio.modified?.timeIntervalSince1970 ?? 0, cue.modified?.timeIntervalSince1970 ?? 0)
                    let keys = sheet.tracks.filter { $0.fileName == sheetFile }.map { "\(audioURI)#cue=\($0.number)" }
                    let unchanged = !full && !audio.isPlaceholder && !keys.isEmpty && keys.allSatisfy { key in
                        guard let row = existingRows[key], let stored = row.0 else { return false }
                        return abs(stored - modified) < 1 && row.1 == audio.size
                    }
                    if unchanged {
                        keep.formUnion(keys)
                        summary.unchanged += keys.count
                    } else {
                        jobs.append(.cue(cue: cue, sheet: sheet, sheetFileName: sheetFile, audio: audio, directory: listing))
                    }
                }
            }
            for audio in listing.audio where !covered.contains(audio.url.path) {
                let key = SourceURI.file(audio.url)
                if !full, let row = existingRows[key] {
                    let storedModified = row.0
                    let currentModified = audio.modified?.timeIntervalSince1970
                    let same: Bool
                    if audio.isPlaceholder {
                        same = true
                    } else if let storedModified, let currentModified {
                        same = abs(storedModified - currentModified) < 1 && row.1 == audio.size
                    } else {
                        same = false
                    }
                    if same {
                        keep.insert(key)
                        summary.unchanged += 1
                        continue
                    }
                }
                jobs.append(.file(audio, directory: listing))
            }
        }

        let total = jobs.count
        progress(ScanProgress(phase: .reading, folderName: folder.name, processed: 0, total: total))
        var pending: [Track] = []
        var processed = 0
        var lastReport = Date.distantPast
        let maxConcurrent = 4

        try await withThrowingTaskGroup(of: [Track].self) { group in
            var iterator = jobs.makeIterator()
            func addNext() -> Bool {
                guard let job = iterator.next() else { return false }
                group.addTask { [self] in
                    try Task.checkCancellation()
                    return await self.process(job, root: root, folderName: folder.name)
                }
                return true
            }
            for _ in 0..<maxConcurrent {
                if !addNext() { break }
            }
            while let tracks = try await group.next() {
                processed += 1
                if tracks.isEmpty { summary.failed += 1 }
                pending.append(contentsOf: tracks)
                if pending.count >= 200 {
                    try await save(pending, existing: existingRows, summary: &summary)
                    pending.removeAll()
                }
                if Date().timeIntervalSince(lastReport) > 0.25 {
                    lastReport = Date()
                    progress(ScanProgress(phase: .reading, folderName: folder.name, processed: processed, total: total,
                                          currentItem: tracks.first?.fileName ?? ""))
                }
                for track in tracks { keep.insert(track.libraryKey) }
                _ = addNext()
            }
        }
        progress(ScanProgress(phase: .saving, folderName: folder.name, processed: processed, total: total))
        try await save(pending, existing: existingRows, summary: &summary)

        let keepSet = keep
        let removed = try await database.write { db -> Int in
            try LibraryQueries.removeMissing(db, keyPrefix: rootPrefix, keep: keepSet)
        }
        summary.removed = removed

        var updatedFolder = folder
        updatedFolder.lastScan = Date()
        updatedFolder.path = root.path
        let folderRecord = updatedFolder
        try await database.write { db in try folderRecord.save(db) }
        progress(ScanProgress(phase: .finished, folderName: folder.name, processed: total, total: total))
        Log.library.info("Scanned \(folder.name, privacy: .public): +\(summary.added) ~\(summary.updated) -\(summary.removed) =\(summary.unchanged)")
        return summary
    }

    private func save(_ tracks: [Track], existing: [String: (Double?, Int64)], summary: inout ScanSummary) async throws {
        guard !tracks.isEmpty else { return }
        let batch = tracks
        try await database.write { db in
            for track in batch { try LibraryQueries.upsert(db, track) }
        }
        for track in tracks {
            if existing[track.libraryKey] != nil { summary.updated += 1 } else { summary.added += 1 }
        }
    }

    /// Finds the audio file a CUE `FILE` entry refers to (exact name, then same base name with another extension).
    static func matchCueAudio(_ name: String, in listing: DirectoryListing) -> FileInfo? {
        let target = PathUtils.lastComponent(name.replacingOccurrences(of: "\\", with: "/")).lowercased()
        if let exact = listing.audio.first(where: { $0.url.lastPathComponent.lowercased() == target }) { return exact }
        let base = (target as NSString).deletingPathExtension
        return listing.audio.first { $0.url.deletingPathExtension().lastPathComponent.lowercased() == base }
    }

    func process(_ job: Job, root: URL, folderName: String) async -> [Track] {
        switch job {
        case .file(let info, let directory):
            return [await makeTrack(info, directory: directory, root: root, folderName: folderName)]
        case .cue(let cue, let sheet, let sheetFileName, let audio, let directory):
            return await makeCueTracks(cue: cue, sheet: sheet, sheetFileName: sheetFileName, audio: audio, directory: directory,
                                       root: root, folderName: folderName)
        }
    }

    func makeTrack(_ info: FileInfo, directory: DirectoryListing, root: URL, folderName: String) async -> Track {
        let name = info.url.lastPathComponent
        var track = Track(sourceURI: SourceURI.file(info.url), folderPath: folderPath(for: directory.url, root: root, folderName: folderName),
                          fileName: name, title: PathUtils.titleFromFileName(name), fileModified: info.modified, fileSize: info.size)
        track.codec = MetadataReader.normalizeCodec(nil, fileExtension: PathUtils.fileExtension(name))
        if info.isPlaceholder {
            track.fileModified = nil
        } else if let metadata = await MetadataReader.read(url: info.url) {
            metadata.apply(to: &track)
            if let cover = metadata.frontCover { track.artworkKey = artwork.store(cover) }
        }
        if track.artworkKey == nil { track.artworkKey = directoryArtworkKey(directory) }
        let base = (name as NSString).deletingPathExtension.lowercased()
        if directory.lyricsBaseNames.contains(base) { track.hasLyrics = true }
        return track
    }

    func makeCueTracks(cue: FileInfo, sheet: CueSheet, sheetFileName: String, audio: FileInfo, directory: DirectoryListing,
                       root: URL, folderName: String) async -> [Track] {
        let audioURI = SourceURI.file(audio.url)
        let metadata = audio.isPlaceholder ? nil : await MetadataReader.read(url: audio.url)
        let fileDuration = metadata?.duration
        let modified = Date(timeIntervalSince1970: max(audio.modified?.timeIntervalSince1970 ?? 0, cue.modified?.timeIntervalSince1970 ?? 0))
        var coverKey = metadata?.frontCover.flatMap { artwork.store($0) }
        if coverKey == nil { coverKey = directoryArtworkKey(directory) }
        let folder = folderPath(for: directory.url, root: root, folderName: folderName)
        let cueURI = SourceURI.file(cue.url)
        let indices = sheet.tracks.indices.filter { sheet.tracks[$0].fileName == sheetFileName }
        let audioBase = audio.url.deletingPathExtension().lastPathComponent.lowercased()
        let hasSidecarLyrics = directory.lyricsBaseNames.contains(audioBase)
        return indices.map { index in
            let entry = sheet.tracks[index]
            var track = Track(libraryKey: "\(audioURI)#cue=\(entry.number)", sourceURI: audioURI, folderPath: folder,
                              fileName: audio.url.lastPathComponent, title: entry.title, fileModified: modified, fileSize: audio.size)
            metadata?.apply(to: &track)
            track.title = entry.title.isEmpty ? String(format: "Track %02d", entry.number) : entry.title
            let performer = entry.performer.isEmpty ? sheet.performer : entry.performer
            if !performer.isEmpty { track.artist = performer }
            if !sheet.title.isEmpty { track.album = sheet.title }
            if !sheet.performer.isEmpty { track.albumArtist = sheet.performer }
            if let genre = sheet.genre, !genre.isEmpty { track.genre = genre }
            if let year = DateParsing.year(from: sheet.date) { track.year = year }
            if !entry.songwriter.isEmpty { track.composer = entry.songwriter }
            track.trackNumber = entry.number
            track.trackTotal = sheet.tracks.count
            track.lyrics = nil
            track.hasLyrics = hasSidecarLyrics
            track.cueStart = entry.start
            track.cueEnd = sheet.end(ofTrackAt: index)
            track.cueSheetURI = cueURI
            track.duration = sheet.duration(ofTrackAt: index, fileDuration: fileDuration) ?? 0
            track.artworkKey = coverKey
            track.codec = metadata?.codec ?? MetadataReader.normalizeCodec(nil, fileExtension: PathUtils.fileExtension(audio.url.lastPathComponent))
            if let gain = LibraryScanEngine.decibels(entry.rem["REPLAYGAIN_TRACK_GAIN"]) { track.replayGainTrackGain = gain }
            if let peak = entry.rem["REPLAYGAIN_TRACK_PEAK"].flatMap(Double.init) { track.replayGainTrackPeak = peak }
            if let gain = LibraryScanEngine.decibels(sheet.rem["REPLAYGAIN_ALBUM_GAIN"]) { track.replayGainAlbumGain = gain }
            if let peak = sheet.rem["REPLAYGAIN_ALBUM_PEAK"].flatMap(Double.init) { track.replayGainAlbumPeak = peak }
            return track
        }
    }

    static func decibels(_ text: String?) -> Double? {
        guard let text else { return nil }
        let number = text.replacingOccurrences(of: "dB", with: "", options: .caseInsensitive).trimmingCharacters(in: .whitespaces)
        return Double(number)
    }
}

/// Scans watched folders into the library, keeps them in sync with file system changes and imports files.
/// Main-actor observable: bind `isScanning` / `progress` to the UI.
@MainActor
public final class LibraryScanner: ObservableObject {
    @Published public private(set) var isScanning = false
    @Published public private(set) var progress = ScanProgress()
    @Published public private(set) var lastSummary: ScanSummary?
    @Published public private(set) var lastError: String?

    public let repository: LibraryRepository
    public let playlists: PlaylistStore
    private let engine: LibraryScanEngine
    private let paths: AppPaths
    private var scanTask: Task<Void, Never>?
    private var pendingAll = false
    private var pendingFull = false
    private var pendingFolders = Set<String>()
    private var monitors: [String: FolderMonitor] = [:]

    public init(database: MuurDatabase, artwork: ArtworkCache, paths: AppPaths) {
        self.repository = LibraryRepository(database: database)
        self.playlists = PlaylistStore(database: database)
        self.engine = LibraryScanEngine(database: database, artwork: artwork, paths: paths)
        self.paths = paths
    }

    /// The folder scanned by default (Documents on iOS, ~/Music/MuurMusic on macOS).
    public var defaultFolderURL: URL { engine.defaultFolderURL }

    /// Makes sure the default app folder is registered as a watched folder.
    public func ensureDefaultFolder() async {
        do {
            let folders = try await repository.watchedFolders()
            if !folders.contains(where: { $0.isAppDocuments }) {
                #if os(macOS)
                let name = "MuurMusic"
                #else
                let name = "On My Device"
                #endif
                let folder = WatchedFolder(id: "app-documents", name: name, path: defaultFolderURL.path, bookmark: nil, isAppDocuments: true)
                try await repository.save(watchedFolder: folder)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Adds a user-picked folder (document picker / NSOpenPanel URL), persisting a security-scoped bookmark, and scans it.
    @discardableResult
    public func addFolder(url: URL) async throws -> WatchedFolder {
        let bookmark = try SecurityScopeManager.shared.makeBookmark(for: url)
        let existing = try await repository.watchedFolders()
        if let match = existing.first(where: { $0.path == url.path }) {
            scan(folderID: match.id)
            return match
        }
        let folder = WatchedFolder(name: url.lastPathComponent, path: url.path, bookmark: bookmark)
        try await repository.save(watchedFolder: folder)
        scan(folderID: folder.id)
        restartMonitoringIfNeeded()
        return folder
    }

    /// Removes a watched folder and its tracks.
    public func removeFolder(_ folder: WatchedFolder) async throws {
        monitors[folder.id]?.stop()
        monitors[folder.id] = nil
        try await repository.deleteWatchedFolder(id: folder.id)
        let prefix = LibraryScanEngine.directoryPrefix(URL(fileURLWithPath: folder.path, isDirectory: true))
        try await repository.deleteTracks(uriPrefix: prefix)
        SecurityScopeManager.shared.stopAccessing(key: "folder:" + folder.id)
    }

    public func setFolderEnabled(_ folder: WatchedFolder, enabled: Bool) async throws {
        var updated = folder
        updated.enabled = enabled
        try await repository.save(watchedFolder: updated)
        if enabled { scan(folderID: folder.id) }
        restartMonitoringIfNeeded()
    }

    /// Scans every enabled folder (incrementally unless `full`).
    public func scanAll(full: Bool = false) {
        pendingAll = true
        pendingFull = pendingFull || full
        startLoopIfNeeded()
    }

    public func scan(folderID: String, full: Bool = false) {
        pendingFolders.insert(folderID)
        pendingFull = pendingFull || full
        startLoopIfNeeded()
    }

    /// Incrementally rescans the app's own folder (Documents on iOS), where Wi-Fi transfer, the Files app
    /// and Finder file sharing put music.
    public func scanAppDocuments() {
        Task {
            await ensureDefaultFolder()
            guard let folder = try? await repository.watchedFolders().first(where: { $0.isAppDocuments }) else { return }
            scan(folderID: folder.id)
        }
    }

    public func cancel() {
        pendingAll = false
        pendingFolders.removeAll()
        scanTask?.cancel()
    }

    /// Suspends until no scan is running.
    public func waitUntilIdle() async {
        while let task = scanTask {
            await task.value
        }
    }

    private func startLoopIfNeeded() {
        guard scanTask == nil else { return }
        scanTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    private func runLoop() async {
        isScanning = true
        lastError = nil
        while pendingAll || !pendingFolders.isEmpty {
            let all = pendingAll
            let ids = pendingFolders
            let full = pendingFull
            pendingAll = false
            pendingFolders.removeAll()
            pendingFull = false
            let folders = (try? await repository.watchedFolders()) ?? []
            for folder in folders where folder.enabled && (all || ids.contains(folder.id)) {
                if Task.isCancelled { break }
                do {
                    let summary = try await engine.scan(folder: folder, full: full) { [weak self] update in
                        Task { @MainActor [weak self] in self?.progress = update }
                    }
                    lastSummary = summary
                } catch is CancellationError {
                    break
                } catch {
                    Log.library.error("Scan of \(folder.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    lastError = "\(folder.name): \(error.localizedDescription)"
                }
            }
            if Task.isCancelled { break }
        }
        progress = ScanProgress(phase: .idle)
        isScanning = false
        scanTask = nil
    }

    // MARK: Import

    /// Copies files or folders (from the document picker, drag & drop, share sheet) into the default library folder,
    /// extracting ZIP archives and importing playlist files as playlists, then scans. Returns the copied URLs.
    @discardableResult
    public func importFiles(_ urls: [URL]) async throws -> [URL] {
        let destinationRoot = paths.musicFolder
        let playlistStore = playlists
        let copied: [URL] = try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            try fm.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
            var result: [URL] = []
            for url in urls {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                if PathUtils.isArchive(url.lastPathComponent) {
                    let target = LibraryScanner.uniqueURL(destinationRoot.appendingPathComponent(url.deletingPathExtension().lastPathComponent, isDirectory: true))
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                    try fm.unzipItem(at: url, to: target)
                    result.append(target)
                    continue
                }
                let target = LibraryScanner.uniqueURL(destinationRoot.appendingPathComponent(url.lastPathComponent))
                try fm.copyItem(at: url, to: target)
                result.append(target)
            }
            return result
        }.value
        for url in copied where PathUtils.isPlaylist(url.lastPathComponent) && PathUtils.fileExtension(url.lastPathComponent) != "cue" {
            if let data = try? Data(contentsOf: url) {
                _ = try? await playlistStore.importPlaylist(data: data, fileName: url.lastPathComponent, fileURI: SourceURI.file(url))
            }
        }
        await ensureDefaultFolder()
        if let folder = try await repository.watchedFolders().first(where: { $0.isAppDocuments }) {
            scan(folderID: folder.id)
        }
        return copied
    }

    nonisolated static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let directory = url.deletingLastPathComponent()
        var counter = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }

    // MARK: Monitoring

    /// Watches enabled folders and rescans them (debounced) when their contents change.
    public func startMonitoring() {
        Task { await self.configureMonitors() }
    }

    public func stopMonitoring() {
        for monitor in monitors.values { monitor.stop() }
        monitors.removeAll()
    }

    private func restartMonitoringIfNeeded() {
        guard !monitors.isEmpty else { return }
        startMonitoring()
    }

    private func configureMonitors() async {
        stopMonitoring()
        guard let folders = try? await repository.watchedFolders() else { return }
        for folder in folders where folder.enabled {
            guard let root = try? await engine.rootURL(for: folder) else { continue }
            let folderID = folder.id
            let monitor = FolderMonitor(url: root, debounce: 3) { [weak self] in
                Task { @MainActor [weak self] in self?.scan(folderID: folderID) }
            }
            monitor.start()
            monitors[folder.id] = monitor
        }
    }
}
