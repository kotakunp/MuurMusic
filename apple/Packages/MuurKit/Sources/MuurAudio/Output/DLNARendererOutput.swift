import Foundation
import MuurCore
import Network

/// A DLNA / UPnP media renderer used as playback output (FEATURES "DLNA casting").
/// Control goes through AVTransport / RenderingControl SOAP actions; the renderer pulls audio over
/// HTTP from either the source's direct URL or the built-in `LocalAudioServer`.
public final class DLNARenderer: Sendable {
    public let device: UPnPDevice
    private let avTransport: UPnPService
    private let renderingControl: UPnPService?
    private let http: HTTPClient

    public var displayName: String { device.friendlyName }
    /// Unique enough for settings persistence.
    public var id: String { device.id }

    public init(device: UPnPDevice, http: HTTPClient = .shared) throws {
        guard let avTransport = device.service(SSDPDiscovery.avTransport) else {
            throw MuurError.unsupported("\(device.friendlyName) is not a media renderer")
        }
        self.device = device
        self.avTransport = avTransport
        self.renderingControl = device.service(SSDPDiscovery.renderingControl)
        self.http = http
    }

    /// Discovers renderers on the local network (SSDP).
    public static func discover(timeout: TimeInterval = 3, http: HTTPClient = .shared) async -> [DLNARenderer] {
        await UPnPDevice.discover(type: SSDPDiscovery.mediaRenderer, timeout: timeout, http: http)
            .filter(\.isMediaRenderer)
            .compactMap { try? DLNARenderer(device: $0, http: http) }
    }

    public static func load(from descriptionURL: URL, http: HTTPClient = .shared) async throws -> DLNARenderer {
        let device = try await UPnPDevice.load(from: descriptionURL, http: http)
        return try DLNARenderer(device: device, http: http)
    }

    /// Points the renderer at an audio URL with DIDL-Lite metadata, then starts playback.
    public func play(url: URL, track: Track, mimeType: String, artworkURL: URL? = nil) async throws {
        let didl = DIDLParser.metadata(title: track.displayTitle, artist: track.displayArtist, album: track.album,
                                       url: url, mimeType: mimeType, duration: track.duration, albumArtURL: artworkURL)
        _ = try await UPnPSOAP.call("SetAVTransportURI", service: avTransport, arguments: [
            ("InstanceID", "0"), ("CurrentURI", url.absoluteString), ("CurrentURIMetaData", didl),
        ], http: http)
        try await play()
    }

    public func play() async throws {
        _ = try await UPnPSOAP.call("Play", service: avTransport, arguments: [("InstanceID", "0"), ("Speed", "1")], http: http)
    }

    public func pause() async throws {
        _ = try await UPnPSOAP.call("Pause", service: avTransport, arguments: [("InstanceID", "0")], http: http)
    }

    public func stop() async throws {
        _ = try await UPnPSOAP.call("Stop", service: avTransport, arguments: [("InstanceID", "0")], http: http)
    }

    public func seek(to seconds: Double) async throws {
        _ = try await UPnPSOAP.call("Seek", service: avTransport, arguments: [
            ("InstanceID", "0"), ("Unit", "REL_TIME"), ("Target", DIDLParser.formatDuration(seconds)),
        ], http: http)
    }

    /// Renderer volume 0...100 (nothing happens when RenderingControl is missing).
    public func setVolume(_ volume: Int) async throws {
        guard let renderingControl else { return }
        _ = try await UPnPSOAP.call("SetVolume", service: renderingControl, arguments: [
            ("InstanceID", "0"), ("Channel", "Master"), ("DesiredVolume", String(min(max(volume, 0), 100))),
        ], http: http)
    }

    public func volume() async throws -> Int? {
        guard let renderingControl else { return nil }
        let result = try await UPnPSOAP.call("GetVolume", service: renderingControl, arguments: [("InstanceID", "0"), ("Channel", "Master")], http: http)
        return result["CurrentVolume"].flatMap(Int.init)
    }

    public struct Position: Sendable, Hashable {
        public var trackSeconds: Double
        public var durationSeconds: Double
        public var state: String
        public var isPlaying: Bool { state == "PLAYING" }
        public var isStopped: Bool { state == "STOPPED" || state == "NO_MEDIA_PRESENT" }
    }

    /// Current transport state and track position (poll while casting).
    public func position() async throws -> Position {
        async let info = UPnPSOAP.call("GetTransportInfo", service: avTransport, arguments: [("InstanceID", "0")], http: http)
        async let position = UPnPSOAP.call("GetPositionInfo", service: avTransport, arguments: [("InstanceID", "0")], http: http)
        let (transport, track) = try await (info, position)
        return Position(trackSeconds: DIDLParser.parseDuration(track["RelTime"] ?? ""),
                        durationSeconds: DIDLParser.parseDuration(track["TrackDuration"] ?? ""),
                        state: transport["CurrentTransportState"] ?? "STOPPED")
    }
}

// MARK: - Local audio HTTP server

/// Tiny HTTP server that serves local audio files (with `Range` support) to DLNA renderers.
/// Files are registered per track; the URL carries an unguessable token.
public final class LocalAudioServer: @unchecked Sendable {
    private struct RegisteredFile {
        var url: URL
        var mimeType: String
    }

    private let files = LockedValue<[String: RegisteredFile]>([:])
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "app.muur.audio-server", qos: .userInitiated)
    public private(set) var port: UInt16 = 0

    public init() {}

    public var isRunning: Bool { listener != nil }

    public func start() throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let newListener = try NWListener(using: parameters)
        newListener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.port = newListener.port?.rawValue ?? 0
            }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        newListener.start(queue: queue)
        listener = newListener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        port = 0
    }

    /// Registers a file and returns the URL a renderer should fetch. Prefers the Wi-Fi/Ethernet
    /// address of the device (renderers cannot reach `127.0.0.1`).
    public func url(for file: URL, fileName: String) -> URL? {
        let token = Hashing.randomToken(length: 20)
        files.mutate { $0[token] = RegisteredFile(url: file, mimeType: PathUtils.mimeType(forExtension: PathUtils.fileExtension(fileName))) }
        let host = WiFiTransferServer.localIPv4Addresses().first ?? "127.0.0.1"
        let encodedName = PathUtils.percentEncodePath(fileName)
        return URL(string: "http://\(host):\(port)/audio/\(token)/\(encodedName)")
    }

    public func unregisterAll() {
        files.mutate { $0.removeAll() }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let request = LocalAudioServer.parseHead(data) else {
                connection.cancel()
                return
            }
            self.serve(request, on: connection)
        }
    }

    private struct Head {
        var method: String
        var path: String
        var rangeStart: Int64?
        var rangeEnd: Int64?
    }

    private static func parseHead(_ data: Data) -> Head? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        let request = lines.removeFirst().split(separator: " ")
        guard request.count >= 2 else { return nil }
        var head = Head(method: String(request[0]).uppercased(), path: String(request[1]), rangeStart: nil, rangeEnd: nil)
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("range:") {
                let value = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                guard value.hasPrefix("bytes=") else { continue }
                let range = value.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
                head.rangeStart = Int64(range[0])
                if range.count > 1 { head.rangeEnd = Int64(range[1]) }
            }
        }
        return head
    }

    private func serve(_ head: Head, on connection: NWConnection) {
        let components = head.path.split(separator: "/").map(String.init)
        guard components.count >= 2, components[0] == "audio",
              let file = files.get()[components[1]] else {
            LocalAudioServer.respond(connection, status: 404, reason: "Not Found", headers: [:], body: nil)
            return
        }
        let fm = FileManager.default
        guard let size = ((try? fm.attributesOfItem(atPath: file.url.path))?[.size] as? NSNumber)?.int64Value,
              let handle = try? FileHandle(forReadingFrom: file.url) else {
            LocalAudioServer.respond(connection, status: 404, reason: "Not Found", headers: [:], body: nil)
            return
        }
        var start = head.rangeStart ?? 0
        var end = head.rangeEnd ?? (size - 1)
        if head.rangeStart == nil, head.rangeEnd != nil {
            // Suffix range: last N bytes.
            start = max(0, size - end)
            end = size - 1
        }
        end = min(end, size - 1)
        let isRange = head.rangeStart != nil || head.rangeEnd != nil
        if start > end || start < 0 {
            try? handle.close()
            LocalAudioServer.respond(connection, status: 416, reason: "Range Not Satisfiable",
                                     headers: ["Content-Range": "bytes */\(size)"], body: nil)
            return
        }
        var headers: [String: String] = [
            "Content-Type": file.mimeType,
            "Accept-Ranges": "bytes",
        ]
        let status: Int
        let reason: String
        if isRange {
            status = 206
            reason = "Partial Content"
            headers["Content-Range"] = "bytes \(start)-\(end)/\(size)"
            headers["Content-Length"] = String(end - start + 1)
        } else {
            status = 200
            reason = "OK"
            headers["Content-Length"] = String(size)
        }
        if head.method == "HEAD" {
            try? handle.close()
            LocalAudioServer.respond(connection, status: status, reason: reason, headers: headers, body: Data())
            return
        }
        // Header first, then the requested byte range in chunks.
        var text = "HTTP/1.1 \(status) \(reason)\r\n"
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) { text += "\(key): \(value)\r\n" }
        text += "Connection: close\r\n\r\n"
        connection.send(content: Data(text.utf8), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { try? handle.close(); connection.cancel(); return }
            if isRange { try? handle.seek(toOffset: UInt64(start)) }
            self.stream(handle: handle, remaining: end - start + 1, on: connection)
        })
    }

    private func stream(handle: FileHandle, remaining: Int64, on connection: NWConnection) {
        guard remaining > 0 else {
            try? handle.close()
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }
        let chunk = (try? handle.read(upToCount: Int(min(remaining, 256 * 1024)))) ?? Data()
        if chunk.isEmpty {
            try? handle.close()
            connection.cancel()
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { try? handle.close(); connection.cancel(); return }
            self.stream(handle: handle, remaining: remaining - Int64(chunk.count), on: connection)
        })
    }

    private static func respond(_ connection: NWConnection, status: Int, reason: String, headers: [String: String], body: Data?) {
        var text = "HTTP/1.1 \(status) \(reason)\r\n"
        for (key, value) in headers { text += "\(key): \(value)\r\n" }
        text += "Content-Length: \(body?.count ?? 0)\r\nConnection: close\r\n\r\n"
        var data = Data(text.utf8)
        if let body { data.append(body) }
        connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
