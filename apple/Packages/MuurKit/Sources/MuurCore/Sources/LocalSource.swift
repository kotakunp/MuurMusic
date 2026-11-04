import Foundation

extension SourceConfig.OptionKey {
    /// Base64 security-scoped bookmark of the folder picked for a local / iCloud Drive source.
    public static let bookmark = "bookmark"
}

/// A folder on the device, an external drive, or iCloud Drive.
///
/// `.local`: the folder is resolved from `OptionKey.bookmark` (empty = the app's music folder).
/// `.iCloud`: the bookmark of a user-picked iCloud Drive folder, or the app's ubiquity container
/// `Documents` folder when no bookmark is stored (requires the iCloud Documents entitlement).
/// Items use `file://` URIs; iCloud placeholders are downloaded on demand.
public final class LocalSource: MusicSource {
    public let config: SourceConfig
    public var capabilities: SourceCapabilities { SourceCapabilities.fileServer.union(.search) }
    private let paths: AppPaths
    private let rootURL: LockedValue<URL?> = LockedValue(nil)

    public init(config: SourceConfig, paths: AppPaths) {
        self.config = config
        self.paths = paths
    }

    /// Stores a bookmark for `url` into a configuration.
    public static func configure(_ config: inout SourceConfig, folder url: URL) throws {
        let data = try SecurityScopeManager.shared.makeBookmark(for: url)
        config.options[SourceConfig.OptionKey.bookmark] = data.base64EncodedString()
        config.basePath = url.path
        if config.name.isEmpty { config.name = url.lastPathComponent }
    }

    /// The resolved root folder.
    public func root() throws -> URL {
        if let cached = rootURL.get() { return cached }
        let url: URL
        if let encoded = config.option(SourceConfig.OptionKey.bookmark), let data = Data(base64Encoded: encoded) {
            url = try SecurityScopeManager.shared.startAccessing(bookmark: data, key: "source-" + config.id.uuidString)
        } else if config.kind == .iCloud {
            guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
                throw MuurError.notConfigured("iCloud Drive (sign in to iCloud and enable iCloud Drive)")
            }
            url = container.appendingPathComponent("Documents", isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else if !config.basePath.isEmpty {
            url = URL(fileURLWithPath: config.basePath, isDirectory: true)
        } else {
            url = paths.musicFolder
        }
        rootURL.set(url)
        return url
    }

    public func connect() async throws {
        let url = try root()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MuurError.notFound(url.path)
        }
    }

    public func disconnect() async {
        SecurityScopeManager.shared.stopAccessing(key: "source-" + config.id.uuidString)
        rootURL.set(nil)
    }

    private func folderURL(_ container: SourceItem?) throws -> URL {
        if let container { return URL(fileURLWithPath: container.path, isDirectory: true) }
        return try root()
    }

    private func item(for url: URL) -> SourceItem? {
        var name = url.lastPathComponent
        var target = url
        let isPlaceholder = name.hasPrefix(".") && name.hasSuffix(".icloud")
        if isPlaceholder {
            target = UbiquityHelper.resolvePlaceholder(url)
            name = target.lastPathComponent
        } else if name.hasPrefix(".") {
            return nil
        }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isPackageKey])
        let isDirectory = values?.isDirectory == true && values?.isPackage != true
        let kind: SourceItem.Kind = isDirectory ? .folder : SourceItem.kind(forFileName: name)
        return SourceItem(uri: SourceURI.file(target), name: name, kind: kind, path: target.path,
                          size: values?.fileSize.map(Int64.init), modified: values?.contentModificationDate,
                          mimeType: isDirectory ? nil : PathUtils.mimeType(forExtension: PathUtils.fileExtension(name)),
                          subtitle: isPlaceholder ? "In iCloud" : nil)
    }

    public func list(_ container: SourceItem?) async throws -> [SourceItem] {
        let folder = try folderURL(container)
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isPackageKey],
            options: [])
        return urls.compactMap(item(for:)).sorted {
            ($0.kind == .folder ? 0 : 1, $0.name.localizedLowercase) < ($1.kind == .folder ? 0 : 1, $1.name.localizedLowercase)
        }
    }

    public func search(_ text: String) async throws -> [SourceItem] {
        let needle = text.lowercased()
        guard !needle.isEmpty else { return [] }
        let base = try root()
        guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey],
                                                              options: [.skipsPackageDescendants]) else { return [] }
        var results: [SourceItem] = []
        while let url = enumerator.nextObject() as? URL {
            if results.count >= 500 { break }
            if url.lastPathComponent.lowercased().contains(needle), let item = self.item(for: url) {
                results.append(item)
            }
        }
        return results
    }

    public func download(uri: String, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        guard let parsed = SourceURI.parse(uri), parsed.isFile else { throw MuurError.invalidData("Not a file URI") }
        let source = try await UbiquityHelper.ensureDownloaded(URL(fileURLWithPath: parsed.path))
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.copyItem(at: source, to: destination)
        let size = ((try? fm.attributesOfItem(atPath: destination.path))?[.size] as? NSNumber)?.int64Value ?? 0
        progress(size, size)
    }

    public func upload(from localURL: URL, to container: SourceItem?, fileName: String) async throws {
        let folder = try folderURL(container)
        var target = folder.appendingPathComponent(PathUtils.sanitizeFileName(fileName))
        let fm = FileManager.default
        var counter = 2
        let base = target.deletingPathExtension().lastPathComponent
        let ext = target.pathExtension
        while fm.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)")
            counter += 1
        }
        try fm.copyItem(at: localURL, to: target)
    }

    public func delete(_ item: SourceItem) async throws {
        try FileManager.default.removeItem(at: URL(fileURLWithPath: item.path))
    }

    public func rename(_ item: SourceItem, to newName: String) async throws {
        let url = URL(fileURLWithPath: item.path)
        try FileManager.default.moveItem(at: url, to: url.deletingLastPathComponent().appendingPathComponent(PathUtils.sanitizeFileName(newName)))
    }

    public func createFolder(named name: String, in container: SourceItem?) async throws {
        let folder = try folderURL(container)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(PathUtils.sanitizeFileName(name), isDirectory: true),
                                                withIntermediateDirectories: false)
    }
}
