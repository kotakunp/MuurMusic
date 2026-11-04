import Foundation
import Citadel
import Crypto
import NIOCore

/// SFTP servers through Citadel (SwiftNIO SSH).
///
/// `config.host`, `config.port` (22), `config.username`; `SourceSecrets.password` or
/// `SourceSecrets.privateKey` (OpenSSH ed25519 / RSA, optional `privateKeyPassphrase`);
/// option `sftpAuth` = "key" forces key authentication. `config.basePath` = start folder (empty = home).
/// URIs: `sftp://host[:port]/absolute/path`.
///
/// Host keys are accepted without verification (Citadel offers no known-hosts store); use SFTP on
/// trusted networks or behind a VPN.
public final class SFTPSource: MusicSource {
    public let config: SourceConfig
    public var capabilities: SourceCapabilities { SourceCapabilities.fileServer }
    private let session: Session

    actor Session {
        private let config: SourceConfig
        private let secrets: SourceSecrets
        private var client: SSHClient?
        private var sftp: SFTPClient?
        private(set) var homePath: String?

        init(config: SourceConfig, secrets: SourceSecrets) {
            self.config = config
            self.secrets = secrets
        }

        private func authentication() throws -> SSHAuthenticationMethod {
            let user = config.username
            let wantsKey = config.option(SourceConfig.OptionKey.sftpAuth) == "key"
                || (secrets.password ?? "").isEmpty && !(secrets.privateKey ?? "").isEmpty
            if wantsKey {
                guard let keyText = secrets.privateKey, !keyText.isEmpty else { throw MuurError.notConfigured("SFTP private key") }
                let passphrase = secrets.privateKeyPassphrase.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
                if let key = try? Curve25519.Signing.PrivateKey(sshEd25519: keyText, decryptionKey: passphrase) {
                    return .ed25519(username: user, privateKey: key)
                }
                do {
                    let key = try Insecure.RSA.PrivateKey(sshRsa: keyText, decryptionKey: passphrase)
                    return .rsa(username: user, privateKey: key)
                } catch {
                    throw MuurError.invalidData("Unsupported private key (use an OpenSSH ed25519 or RSA key): \(error.localizedDescription)")
                }
            }
            return .passwordBased(username: user, password: secrets.password ?? "")
        }

        func client() async throws -> SFTPClient {
            if let sftp, sftp.isActive { return sftp }
            await reset()
            do {
                let ssh = try await SSHClient.connect(host: config.host, port: config.port ?? 22,
                                                      authenticationMethod: try authentication(),
                                                      hostKeyValidator: .acceptAnything(), reconnect: .never)
                let opened = try await ssh.openSFTP()
                client = ssh
                sftp = opened
                if homePath == nil {
                    homePath = (try? await opened.getRealPath(atPath: ".")) ?? "/"
                }
                return opened
            } catch let error as MuurError {
                throw error
            } catch {
                let text = String(describing: error)
                if text.localizedCaseInsensitiveContains("auth") {
                    throw MuurError.authenticationFailed(text)
                }
                throw MuurError.network(text)
            }
        }

        func reset() async {
            if let sftp { try? await sftp.close() }
            if let client { try? await client.close() }
            sftp = nil
            client = nil
        }
    }

    public init(config: SourceConfig, secrets: SourceSecrets) throws {
        guard !config.host.isEmpty else { throw MuurError.notConfigured("SFTP server address") }
        guard !config.username.isEmpty else { throw MuurError.notConfigured("SFTP user name") }
        self.config = config
        session = Session(config: config, secrets: secrets)
    }

    private func rootPath() async throws -> String {
        let base = config.basePath.trimmingCharacters(in: .whitespaces)
        if base.hasPrefix("/") { return SourcePaths.root(base) }
        _ = try await session.client()
        let home = await session.homePath ?? "/"
        return base.isEmpty ? home : SourcePaths.child(home, base)
    }

    private func uri(for path: String) -> String {
        SourceURI(scheme: "sftp", authority: config.host, path: path, port: config.port == 22 ? nil : config.port).description
    }

    public func connect() async throws {
        let sftp = try await session.client()
        _ = try await sftp.listDirectory(atPath: try await rootPath())
    }

    public func disconnect() async {
        await session.reset()
    }

    private static let typeMask: UInt32 = 0o170000
    private static let directoryType: UInt32 = 0o040000
    private static let symlinkType: UInt32 = 0o120000

    public func list(_ container: SourceItem?) async throws -> [SourceItem] {
        let path: String
        if let container { path = container.path } else { path = try await rootPath() }
        let sftp = try await session.client()
        let names: [SFTPMessage.Name]
        do {
            names = try await sftp.listDirectory(atPath: path)
        } catch {
            await session.reset()
            throw MuurError.network("Listing \(path) failed: \(error)")
        }
        var items: [SourceItem] = []
        for component in names.flatMap(\.components) {
            let name = component.filename
            guard name != ".", name != "..", !name.hasPrefix(".") else { continue }
            let childPath = SourcePaths.child(path, name)
            var attributes = component.attributes
            var type = (attributes.permissions ?? 0) & SFTPSource.typeMask
            if type == SFTPSource.symlinkType, let resolved = try? await sftp.getAttributes(at: childPath) {
                attributes = resolved
                type = (resolved.permissions ?? 0) & SFTPSource.typeMask
            }
            let isDirectory = attributes.permissions != nil ? type == SFTPSource.directoryType : component.longname.hasPrefix("d")
            items.append(SourceItem(uri: uri(for: childPath), name: name,
                                    kind: isDirectory ? .folder : SourceItem.kind(forFileName: name), path: childPath,
                                    size: isDirectory ? nil : attributes.size.map { Int64(clamping: $0) },
                                    modified: attributes.accessModificationTime?.modificationTime))
        }
        return items.sorted {
            ($0.kind == .folder ? 0 : 1, $0.name.localizedLowercase) < ($1.kind == .folder ? 0 : 1, $1.name.localizedLowercase)
        }
    }

    public func download(uri: String, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        guard let parsed = SourceURI.parse(uri), parsed.scheme == "sftp" else { throw MuurError.invalidData("Not an SFTP URI") }
        let sftp = try await session.client()
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        guard fm.createFile(atPath: destination.path, contents: nil) else { throw MuurError.io("Cannot create \(destination.lastPathComponent)") }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        do {
            let file = try await sftp.openFile(filePath: parsed.path, flags: .read)
            let total = Int64(clamping: (try? await file.readAttributes().size) ?? 0)
            var offset: UInt64 = 0
            while true {
                try Task.checkCancellation()
                let buffer = try await file.read(from: offset, length: 64 * 1024)
                guard buffer.readableBytes > 0, let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) else { break }
                try handle.write(contentsOf: bytes)
                offset += UInt64(bytes.count)
                progress(Int64(offset), total)
            }
            try? await file.close()
        } catch is CancellationError {
            try? fm.removeItem(at: destination)
            throw MuurError.cancelled
        } catch {
            try? fm.removeItem(at: destination)
            throw MuurError.network("Download failed: \(error)")
        }
    }

    private func containerPath(_ container: SourceItem?) async throws -> String {
        if let container { return container.path }
        return try await rootPath()
    }

    public func upload(from localURL: URL, to container: SourceItem?, fileName: String) async throws {
        let target = SourcePaths.child(try await containerPath(container), fileName)
        let sftp = try await session.client()
        let input = try FileHandle(forReadingFrom: localURL)
        defer { try? input.close() }
        do {
            let file = try await sftp.openFile(filePath: target, flags: [.write, .create, .truncate])
            var offset: UInt64 = 0
            while let chunk = try input.read(upToCount: 256 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                try await file.write(ByteBuffer(bytes: chunk), at: offset)
                offset += UInt64(chunk.count)
            }
            try await file.close()
        } catch {
            throw MuurError.network("Upload failed: \(error)")
        }
    }

    public func delete(_ item: SourceItem) async throws {
        let sftp = try await session.client()
        do {
            if item.kind == .folder {
                try await sftp.rmdir(at: item.path)
            } else {
                try await sftp.remove(at: item.path)
            }
        } catch {
            throw MuurError.protocolError("Delete failed: \(error)")
        }
    }

    public func rename(_ item: SourceItem, to newName: String) async throws {
        let sftp = try await session.client()
        do {
            try await sftp.rename(at: item.path, to: SourcePaths.child(PathUtils.parent(item.path), newName))
        } catch {
            throw MuurError.protocolError("Rename failed: \(error)")
        }
    }

    public func createFolder(named name: String, in container: SourceItem?) async throws {
        let sftp = try await session.client()
        do {
            try await sftp.createDirectory(atPath: SourcePaths.child(try await containerPath(container), name))
        } catch {
            throw MuurError.protocolError("Creating folder failed: \(error)")
        }
    }
}
