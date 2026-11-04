import Foundation

/// LRU cache of remote audio files streamed for playback (`AppPaths.audioCacheDirectory`).
///
/// Files are keyed by source URI. The size limit is read on every insert (settings may change);
/// pinned URIs (the current and next queue items) are never evicted.
public actor AudioCache {
    struct Entry: Codable {
        var fileName: String
        var size: Int64
        var lastAccess: Date
    }

    public let directory: URL
    private let limitBytes: @Sendable () -> Int64
    private var index: [String: Entry] = [:]
    private var inFlight: [String: Task<URL, Error>] = [:]
    private var pinned: Set<String> = []
    private var dirty = false
    private var loaded = false

    public init(directory: URL, limitBytes: @escaping @Sendable () -> Int64) {
        self.directory = directory
        self.limitBytes = limitBytes
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL), let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            index = decoded.filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.value.fileName).path) }
        }
        // Remove orphaned files (e.g. interrupted downloads).
        let known = Set(index.values.map(\.fileName))
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where name != "index.json" && !known.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private func persist() {
        guard dirty else { return }
        dirty = false
        if let data = try? JSONEncoder().encode(index) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    static func fileName(for uri: String, fileExtension: String) -> String {
        let ext = fileExtension.isEmpty ? "audio" : fileExtension.lowercased()
        return String(Hashing.sha256Hex(uri).prefix(40)) + "." + ext
    }

    /// The cached file for `uri`, marking it as recently used.
    public func cachedURL(for uri: String) -> URL? {
        loadIfNeeded()
        guard var entry = index[uri] else { return nil }
        let url = directory.appendingPathComponent(entry.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            index[uri] = nil
            dirty = true
            return nil
        }
        entry.lastAccess = Date()
        index[uri] = entry
        dirty = true
        return url
    }

    public func contains(_ uri: String) -> Bool {
        loadIfNeeded()
        return index[uri] != nil
    }

    /// Returns the cached file or runs `fetch` (once, even for concurrent callers) to download it into the cache.
    /// When `fileExtension` is empty or not an audio extension, the extension is detected from the downloaded content.
    public func file(for uri: String, fileExtension: String,
                     fetch: @escaping @Sendable (URL) async throws -> Void) async throws -> URL {
        if let cached = cachedURL(for: uri) { return cached }
        if let running = inFlight[uri] { return try await running.value }
        let stem = String(Hashing.sha256Hex(uri).prefix(40))
        let directory = self.directory
        let partial = directory.appendingPathComponent(stem + ".partial")
        let task = Task<URL, Error> {
            try await fetch(partial)
            var ext = fileExtension.lowercased()
            if !PathUtils.audioExtensions.contains(ext) {
                ext = AudioFormatSniffer.fileExtension(of: partial) ?? (ext.isEmpty ? "audio" : ext)
            }
            let target = directory.appendingPathComponent(AudioCache.fileName(for: uri, fileExtension: ext))
            let fm = FileManager.default
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: partial, to: target)
            return target
        }
        inFlight[uri] = task
        defer { inFlight[uri] = nil }
        do {
            let url = try await task.value
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
            index[uri] = Entry(fileName: url.lastPathComponent, size: size, lastAccess: Date())
            dirty = true
            trim()
            persist()
            return url
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    /// Adds an existing file (moved into the cache).
    @discardableResult
    public func insert(uri: String, movingFile source: URL) throws -> URL {
        loadIfNeeded()
        let name = AudioCache.fileName(for: uri, fileExtension: source.pathExtension)
        let target = directory.appendingPathComponent(name)
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.moveItem(at: source, to: target)
        let size = ((try? fm.attributesOfItem(atPath: target.path))?[.size] as? NSNumber)?.int64Value ?? 0
        index[uri] = Entry(fileName: name, size: size, lastAccess: Date())
        dirty = true
        trim()
        persist()
        return target
    }

    /// Protects URIs from eviction (replaces the previous set).
    public func pin(_ uris: Set<String>) {
        pinned = uris
    }

    public func remove(_ uri: String) {
        loadIfNeeded()
        if let entry = index.removeValue(forKey: uri) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.fileName))
            dirty = true
            persist()
        }
    }

    public func clear() {
        loadIfNeeded()
        for entry in index.values where true {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.fileName))
        }
        index.removeAll()
        dirty = true
        persist()
    }

    public var totalBytes: Int64 {
        loadIfNeeded()
        return index.values.reduce(0) { $0 + $1.size }
    }

    public var count: Int {
        loadIfNeeded()
        return index.count
    }

    /// Evicts least recently used files until the cache fits the limit.
    public func trim() {
        loadIfNeeded()
        let limit = max(0, limitBytes())
        var total = index.values.reduce(0) { $0 + $1.size }
        guard total > limit else { return }
        for (uri, entry) in index.sorted(by: { $0.value.lastAccess < $1.value.lastAccess }) where !pinned.contains(uri) {
            if total <= limit { break }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.fileName))
            index[uri] = nil
            total -= entry.size
            dirty = true
        }
        persist()
    }
}
