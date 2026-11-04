import Foundation
import ZIPFoundation

/// Browses a ZIP archive (local file, or a remote archive downloaded first by `SourceManager`).
///
/// Items use `zip://<inner URI>!/<entry path>` URIs. Entries are extracted on demand.
public final class ZipArchiveSource: MusicSource {
    public let config: SourceConfig
    public var capabilities: SourceCapabilities { [.browse, .search] }
    /// URI of the archive itself (`file://…` or a remote URI).
    public let archiveURI: String
    /// Local copy of the archive.
    public let archiveURL: URL
    private let entries: [String: (size: Int64, modified: Date?)]

    public init(archiveURL: URL, archiveURI: String, parent: SourceConfig? = nil) throws {
        self.archiveURL = archiveURL
        self.archiveURI = archiveURI
        let archive: Archive
        do {
            archive = try Archive(url: archiveURL, accessMode: .read)
        } catch {
            throw MuurError.invalidData("Could not open ZIP archive: \(error.localizedDescription)")
        }
        var map: [String: (size: Int64, modified: Date?)] = [:]
        for entry in archive where entry.type == .file {
            let path = entry.path
            if path.hasPrefix("__MACOSX/") || PathUtils.lastComponent(path).hasPrefix("._") { continue }
            map[path] = (Int64(entry.uncompressedSize), entry.fileAttributes[.modificationDate] as? Date)
        }
        entries = map
        var base = parent ?? SourceConfig(kind: .local, name: archiveURL.lastPathComponent)
        base.name = archiveURL.lastPathComponent
        config = base
    }

    public func connect() async throws {}

    /// All entry paths (files only).
    public var entryPaths: [String] { entries.keys.sorted() }

    public func list(_ container: SourceItem?) async throws -> [SourceItem] {
        let prefix: String
        if let container, let components = SourceURI.parse(container.uri)?.zipComponents {
            prefix = components.entry.isEmpty || components.entry.hasSuffix("/") ? components.entry : components.entry + "/"
        } else {
            prefix = ""
        }
        var folders: Set<String> = []
        var items: [SourceItem] = []
        for (path, info) in entries where path.hasPrefix(prefix) {
            let rest = String(path.dropFirst(prefix.count))
            if let slash = rest.firstIndex(of: "/") {
                folders.insert(String(rest[..<slash]))
            } else if !rest.isEmpty {
                items.append(SourceItem(uri: SourceURI.zip(inner: archiveURI, entry: path), name: rest,
                                        kind: SourceItem.kind(forFileName: rest), path: path, size: info.size, modified: info.modified))
            }
        }
        let folderItems = folders.map { name in
            SourceItem(uri: SourceURI.zip(inner: archiveURI, entry: prefix + name + "/"), name: name, kind: .folder, path: prefix + name + "/")
        }
        return folderItems.sorted { $0.name.localizedLowercase < $1.name.localizedLowercase }
            + items.sorted { $0.name.localizedLowercase < $1.name.localizedLowercase }
    }

    public func search(_ text: String) async throws -> [SourceItem] {
        let needle = text.lowercased()
        return entries.compactMap { path, info in
            let name = PathUtils.lastComponent(path)
            guard name.lowercased().contains(needle) else { return nil }
            return SourceItem(uri: SourceURI.zip(inner: archiveURI, entry: path), name: name, kind: SourceItem.kind(forFileName: name),
                              path: path, size: info.size, modified: info.modified)
        }
        .sorted { $0.path < $1.path }
    }

    public func download(uri: String, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        guard let components = SourceURI.parse(uri)?.zipComponents else { throw MuurError.invalidData("Not a ZIP URI") }
        try ZipArchiveSource.extract(entry: components.entry, from: archiveURL, to: destination)
        let size = entries[components.entry]?.size ?? 0
        progress(size, size)
    }

    /// Extracts one entry to `destination` (overwriting).
    public static func extract(entry path: String, from archiveURL: URL, to destination: URL) throws {
        let archive: Archive
        do {
            archive = try Archive(url: archiveURL, accessMode: .read)
        } catch {
            throw MuurError.invalidData("Could not open ZIP archive: \(error.localizedDescription)")
        }
        guard let entry = archive[path] else { throw MuurError.notFound(path) }
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        do {
            _ = try archive.extract(entry, to: destination)
        } catch {
            throw MuurError.io("Extracting \(path) failed: \(error.localizedDescription)")
        }
    }
}
