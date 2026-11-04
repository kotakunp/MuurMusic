import Foundation
import Network
#if canImport(Darwin)
import Darwin
#endif

/// A server found on the local network.
public struct DiscoveredService: Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: SourceKind
    public var name: String
    public var host: String
    public var port: Int?
    /// Bonjour service type (`_smb._tcp`) or SSDP device type.
    public var serviceType: String
    /// UPnP device description URL.
    public var descriptionURL: URL?
    public var useTLS: Bool

    public init(id: String, kind: SourceKind, name: String, host: String, port: Int?, serviceType: String, descriptionURL: URL? = nil,
                useTLS: Bool = false) {
        self.id = id
        self.kind = kind
        self.name = name
        self.host = host
        self.port = port
        self.serviceType = serviceType
        self.descriptionURL = descriptionURL
        self.useTLS = useTLS
    }

    /// A pre-filled source configuration (credentials still required).
    public func makeConfig() -> SourceConfig {
        var config = SourceConfig(kind: kind, name: name, host: host, port: port == kind.defaultPort ? nil : port)
        if useTLS { config.options[SourceConfig.OptionKey.useTLS] = "true" }
        if let descriptionURL { config.options[SourceConfig.OptionKey.upnpDescriptionURL] = descriptionURL.absoluteString }
        return config
    }
}

/// Finds SMB, WebDAV, SFTP, FTP and Plex servers via Bonjour, DLNA servers via SSDP and Jellyfin servers via
/// their UDP discovery protocol. Requires `NSLocalNetworkUsageDescription` and `NSBonjourServices`.
@MainActor
public final class SourceDiscovery: ObservableObject {
    @Published public private(set) var services: [DiscoveredService] = []
    @Published public private(set) var isSearching = false

    /// Bonjour service types browsed (also listed in API.md for `NSBonjourServices`).
    public static let bonjourTypes: [(type: String, kind: SourceKind, tls: Bool)] = [
        ("_smb._tcp", .smb, false),
        ("_webdav._tcp", .webdav, false),
        ("_webdavs._tcp", .webdav, true),
        ("_sftp-ssh._tcp", .sftp, false),
        ("_ftp._tcp", .ftp, false),
        ("_plexmediasvr._tcp", .plex, false),
    ]

    private var browsers: [NWBrowser] = []
    private var found: [String: DiscoveredService] = [:]
    private var resolving: Set<String> = []
    private var scanTask: Task<Void, Never>?
    private let queue = DispatchQueue(label: "app.muur.discovery")

    public init() {}

    /// Starts browsing; results accumulate in `services` until `stop()`.
    public func start() {
        stop()
        isSearching = true
        found.removeAll()
        services = []
        for entry in SourceDiscovery.bonjourTypes {
            let parameters = NWParameters()
            parameters.includePeerToPeer = false
            let browser = NWBrowser(for: .bonjour(type: entry.type, domain: nil), using: parameters)
            let kind = entry.kind
            let tls = entry.tls
            let type = entry.type
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                let endpoints = results.map(\.endpoint)
                Task { @MainActor [weak self] in
                    self?.handle(endpoints: endpoints, kind: kind, tls: tls, type: type)
                }
            }
            browser.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    Log.discovery.error("Bonjour browse \(type, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            browser.start(queue: queue)
            browsers.append(browser)
        }
        scanTask = Task { [weak self] in
            async let upnp = UPnPDevice.discover(type: SSDPDiscovery.mediaServer, timeout: 4)
            async let jellyfin = SourceDiscovery.discoverJellyfin(timeout: 3)
            let devices = await upnp
            let servers = await jellyfin
            guard let self, !Task.isCancelled else { return }
            for device in devices where device.isMediaServer {
                self.insert(DiscoveredService(id: "upnp:" + device.id, kind: .upnp, name: device.friendlyName,
                                              host: device.descriptionURL.host ?? "", port: device.descriptionURL.port,
                                              serviceType: device.deviceType, descriptionURL: device.descriptionURL))
            }
            for server in servers { self.insert(server) }
            self.isSearching = false
        }
    }

    public func stop() {
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
        scanTask?.cancel()
        scanTask = nil
        isSearching = false
    }

    private func insert(_ service: DiscoveredService) {
        found[service.id] = service
        services = found.values.sorted { ($0.kind.rawValue, $0.name.localizedLowercase) < ($1.kind.rawValue, $1.name.localizedLowercase) }
    }

    private func handle(endpoints: [NWEndpoint], kind: SourceKind, tls: Bool, type: String) {
        for endpoint in endpoints {
            guard case let .service(name, _, _, _) = endpoint else { continue }
            let id = type + ":" + name
            guard found[id] == nil, !resolving.contains(id) else { continue }
            resolving.insert(id)
            Task { [weak self] in
                let resolved = await SourceDiscovery.resolve(endpoint)
                guard let self else { return }
                self.resolving.remove(id)
                guard let resolved else { return }
                self.insert(DiscoveredService(id: id, kind: kind, name: name, host: resolved.host, port: resolved.port,
                                              serviceType: type, useTLS: tls))
            }
        }
    }

    /// Resolves a Bonjour service endpoint to host and port by opening (and immediately closing) a TCP connection.
    nonisolated static func resolve(_ endpoint: NWEndpoint, timeout: TimeInterval = 5) async -> (host: String, port: Int)? {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        let queue = DispatchQueue(label: "app.muur.discovery.resolve")
        let finished = LockedValue(false)
        return await withCheckedContinuation { (continuation: CheckedContinuation<(host: String, port: Int)?, Never>) in
            func finish(_ value: (host: String, port: Int)?) {
                let already = finished.mutate { flag -> Bool in
                    let was = flag
                    flag = true
                    return was
                }
                guard !already else { return }
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(host, port) = connection.currentPath?.remoteEndpoint {
                        finish((SourceDiscovery.hostString(host), Int(port.rawValue)))
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    nonisolated static func hostString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .name(let name, _): return name
        case .ipv4(let address): return "\(address)"
        case .ipv6(let address):
            let text = "\(address)"
            return "[" + (text.split(separator: "%").first.map(String.init) ?? text) + "]"
        @unknown default: return "\(host)"
        }
    }

    /// Jellyfin answers "who is JellyfinServer?" broadcasts on UDP 7359 with `{"Address","Id","Name"}`.
    nonisolated static func discoverJellyfin(timeout: TimeInterval) async -> [DiscoveredService] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: jellyfinBlocking(timeout: timeout))
            }
        }
    }

    nonisolated static func jellyfinBlocking(timeout: TimeInterval) -> [DiscoveredService] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { Darwin.close(fd) }
        var enable: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &enable, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(7359).bigEndian
        address.sin_addr.s_addr = INADDR_BROADCAST
        let message = Array("who is JellyfinServer?".utf8)
        let sent = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, message, message.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard sent >= 0 else { return [] }
        var results: [DiscoveredService] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(max(1, remaining * 1000)))
            if ready < 0 && errno == EINTR { continue }
            if ready <= 0 { break }
            let capacity = buffer.count
            let count = recv(fd, &buffer, capacity, 0)
            guard count > 0,
                  let object = try? JSONSerialization.jsonObject(with: Data(buffer[0..<count])) as? [String: Any],
                  let addressText = object["Address"] as? String, let url = URL(string: addressText), let host = url.host else { continue }
            let id = "jellyfin:" + ((object["Id"] as? String) ?? addressText)
            results.append(DiscoveredService(id: id, kind: .jellyfin, name: object["Name"] as? String ?? host, host: addressText,
                                             port: nil, serviceType: "jellyfin-udp", useTLS: url.scheme == "https"))
        }
        return results
    }
}
