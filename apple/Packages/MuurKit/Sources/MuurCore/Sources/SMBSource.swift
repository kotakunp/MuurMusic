import Foundation
import AMSMB2

/// SMB 2/3 shares (Windows, macOS, Samba NAS) through AMSMB2 / libsmb2.
///
/// `config.host`: server; `config.username` / `SourceSecrets.password` (empty = guest);
/// options `smbShare` (empty = list shares), `smbDomain`, `useTLS` = "true" requests SMB3 encryption.
/// URIs: `smb://host[:port]/share/path`.
public final class SMBSource: MusicSource {
    public let config: SourceConfig
    public var capabilities: SourceCapabilities { SourceCapabilities.fileServer.union(.search) }
    private let pool: Pool

    actor Pool {
        private let serverURL: URL
        private let domain: String
        private let credential: URLCredential?
        private let encrypted: Bool
        private var managers: [String: SMB2Manager] = [:]

        init(serverURL: URL, domain: String, credential: URLCredential?, encrypted: Bool) {
            self.serverURL = serverURL
            self.domain = domain
            self.credential = credential
            self.encrypted = encrypted
        }

        func makeManager() throws -> SMB2Manager {
            guard let manager = SMB2Manager(url: serverURL, domain: domain, credential: credential) else {
                throw MuurError.invalidData("Invalid SMB server address")
            }
            return manager
        }

        func manager(share: String) async throws -> SMB2Manager {
            if let existing = managers[share] { return existing }
            let manager = try makeManager()
            do {
                try await manager.connectShare(name: share, encrypted: encrypted)
            } catch {
                throw SMBSource.map(error)
            }
            managers[share] = manager
            return manager
        }

        func drop(share: String) {
            managers[share] = nil
        }

        func shares() async throws -> [(name: String, comment: String)] {
            let manager = try makeManager()
            do {
                return try await manager.listShares()
            } catch {
                throw SMBSource.map(error)
            }
        }

        func disconnectAll() async {
            for manager in managers.values {
                try? await manager.disconnectShare(gracefully: true)
            }
            managers.removeAll()
        }
    }

    public init(config: SourceConfig, secrets: SourceSecrets) throws {
        self.config = config
        var components = URLComponents()
        components.scheme = "smb"
        components.host = config.host.trimmingCharacters(in: .whitespaces)
        if let port = config.port, port != 445 { components.port = port }
        guard let url = components.url, !config.host.isEmpty else { throw MuurError.notConfigured("SMB server address") }
        let credential: URLCredential? = config.username.isEmpty
            ? URLCredential(user: "guest", password: "", persistence: .forSession)
            : URLCredential(user: config.username, password: secrets.password ?? "", persistence: .forSession)
        pool = Pool(serverURL: url, domain: config.option(SourceConfig.OptionKey.smbDomain) ?? "", credential: credential,
                    encrypted: config.useTLS)
    }

    static func map(_ error: Error) -> Error {
        if error is MuurError { return error }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain && (nsError.code == Int(EACCES) || nsError.code == Int(EPERM)) {
            return MuurError.authenticationFailed(nsError.localizedDescription)
        }
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT) {
            return MuurError.notFound(nsError.localizedDescription)
        }
        return MuurError.network(nsError.localizedDescription)
    }

    private var fixedShare: String? { config.option(SourceConfig.OptionKey.smbShare) }

    /// "/share/inner/path" for the configured root.
    private var rootPath: String {
        guard let share = fixedShare else { return "/" }
        let base = SourcePaths.root(config.basePath)
        return base == "/" ? "/" + share : "/" + share + base
    }

    /// Splits "/share/a/b" into ("share", "a/b").
    static func split(_ path: String) -> (share: String, inner: String) {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let parts = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
    }

    private func uri(for path: String) -> String {
        SourceURI(scheme: "smb", authority: config.host, path: path, port: config.port == 445 ? nil : config.port).description
    }

    public func connect() async throws {
        if let share = fixedShare {
            let manager = try await pool.manager(share: share)
            do {
                _ = try await manager.contentsOfDirectory(atPath: SMBSource.split(rootPath).inner)
            } catch {
                throw SMBSource.map(error)
            }
        } else {
            _ = try await pool.shares()
        }
    }

    public func disconnect() async {
        await pool.disconnectAll()
    }

    public func list(_ container: SourceItem?) async throws -> [SourceItem] {
        let path = container?.path ?? rootPath
        if path == "/" || path.isEmpty {
            return try await pool.shares()
                .filter { !$0.name.hasSuffix("$") }
                .map { SourceItem(uri: uri(for: "/" + $0.name), name: $0.name, kind: .folder, path: "/" + $0.name,
                                  subtitle: $0.comment.isEmpty ? nil : $0.comment) }
                .sorted { $0.name.localizedLowercase < $1.name.localizedLowercase }
        }
        let (share, inner) = SMBSource.split(path)
        let entries: [[URLResourceKey: Any]]
        do {
            entries = try await listing(share: share, inner: inner)
        } catch {
            throw SMBSource.map(error)
        }
        var items: [SourceItem] = []
        for entry in entries {
            guard let name = entry.name, name != ".", name != "..", !name.hasPrefix(".") else { continue }
            let childPath = SourcePaths.child(path, name)
            let kind: SourceItem.Kind = entry.isDirectory ? .folder : SourceItem.kind(forFileName: name)
            items.append(SourceItem(uri: uri(for: childPath), name: name, kind: kind, path: childPath,
                                    size: entry.isDirectory ? nil : entry.fileSize, modified: entry.contentModificationDate))
        }
        return items.sorted {
            ($0.kind == .folder ? 0 : 1, $0.name.localizedLowercase) < ($1.kind == .folder ? 0 : 1, $1.name.localizedLowercase)
        }
    }

    /// Lists a directory, reconnecting once when the cached connection has gone stale.
    private func listing(share: String, inner: String) async throws -> [[URLResourceKey: Any]] {
        do {
            return try await pool.manager(share: share).contentsOfDirectory(atPath: inner)
        } catch {
            await pool.drop(share: share)
            return try await pool.manager(share: share).contentsOfDirectory(atPath: inner)
        }
    }

    public func search(_ text: String) async throws -> [SourceItem] {
        let needle = text.lowercased()
        guard let share = fixedShare, !needle.isEmpty else { return [] }
        let manager = try await pool.manager(share: share)
        let base = SMBSource.split(rootPath).inner
        let entries: [[URLResourceKey: Any]]
        do {
            entries = try await manager.contentsOfDirectory(atPath: base, recursive: true)
        } catch {
            throw SMBSource.map(error)
        }
        var results: [SourceItem] = []
        for entry in entries {
            guard let name = entry.name, name.lowercased().contains(needle), let relative = entry.path else { continue }
            let inner = relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
            let fullPath = "/" + share + "/" + inner
            results.append(SourceItem(uri: uri(for: fullPath), name: name,
                                      kind: entry.isDirectory ? .folder : SourceItem.kind(forFileName: name),
                                      path: fullPath, size: entry.fileSize, modified: entry.contentModificationDate))
            if results.count >= 500 { break }
        }
        return results
    }

    private func path(of uri: String) throws -> String {
        guard let parsed = SourceURI.parse(uri), parsed.scheme == "smb" else { throw MuurError.invalidData("Not an SMB URI") }
        return parsed.path
    }

    public func download(uri: String, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let (share, inner) = SMBSource.split(try path(of: uri))
        let manager = try await pool.manager(share: share)
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        let cancelled = LockedValue(false)
        do {
            try await withTaskCancellationHandler {
                try await manager.downloadItem(atPath: inner, to: destination, progress: { received, total in
                    progress(received, total)
                    return !cancelled.get()
                })
            } onCancel: {
                cancelled.set(true)
            }
        } catch {
            try? fm.removeItem(at: destination)
            if Task.isCancelled { throw MuurError.cancelled }
            throw SMBSource.map(error)
        }
    }

    private func containerPath(_ container: SourceItem?) throws -> (share: String, inner: String) {
        let parts = SMBSource.split(container?.path ?? rootPath)
        guard !parts.share.isEmpty else { throw MuurError.unsupported("Writing to the server root") }
        return parts
    }

    public func upload(from localURL: URL, to container: SourceItem?, fileName: String) async throws {
        let (share, inner) = try containerPath(container)
        let manager = try await pool.manager(share: share)
        let target = inner.isEmpty ? fileName : inner + "/" + fileName
        do {
            try await manager.uploadItem(at: localURL, toPath: target, progress: nil)
        } catch {
            throw SMBSource.map(error)
        }
    }

    public func delete(_ item: SourceItem) async throws {
        let (share, inner) = SMBSource.split(item.path)
        guard !inner.isEmpty else { throw MuurError.unsupported("Deleting a share") }
        do {
            try await pool.manager(share: share).removeItem(atPath: inner)
        } catch {
            throw SMBSource.map(error)
        }
    }

    public func rename(_ item: SourceItem, to newName: String) async throws {
        let (share, inner) = SMBSource.split(item.path)
        guard !inner.isEmpty else { throw MuurError.unsupported("Renaming a share") }
        let parent = PathUtils.parent("/" + inner)
        let target = (parent == "/" ? "" : String(parent.dropFirst()) + "/") + newName
        do {
            try await pool.manager(share: share).moveItem(atPath: inner, toPath: target)
        } catch {
            throw SMBSource.map(error)
        }
    }

    public func createFolder(named name: String, in container: SourceItem?) async throws {
        let (share, inner) = try containerPath(container)
        do {
            try await pool.manager(share: share).createDirectory(atPath: inner.isEmpty ? name : inner + "/" + name)
        } catch {
            throw SMBSource.map(error)
        }
    }
}
