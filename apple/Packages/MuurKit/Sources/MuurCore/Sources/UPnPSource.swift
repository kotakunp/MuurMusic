import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - SSDP

/// One SSDP search response / announcement.
public struct SSDPResponse: Hashable, Sendable {
    public var location: URL
    public var searchTarget: String
    public var usn: String
    public var server: String

    public init?(_ message: String) {
        var headers: [String: String] = [:]
        for line in message.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).uppercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        guard let locationText = headers["LOCATION"], let url = URL(string: locationText) else { return nil }
        location = url
        searchTarget = headers["ST"] ?? headers["NT"] ?? ""
        usn = headers["USN"] ?? ""
        server = headers["SERVER"] ?? ""
    }
}

/// SSDP M-SEARCH over a UDP socket. On iOS sending multicast requires the
/// `com.apple.developer.networking.multicast` entitlement and local network permission.
public enum SSDPDiscovery {
    public static let mediaServer = "urn:schemas-upnp-org:device:MediaServer:1"
    public static let mediaRenderer = "urn:schemas-upnp-org:device:MediaRenderer:1"
    public static let contentDirectory = "urn:schemas-upnp-org:service:ContentDirectory:1"
    public static let avTransport = "urn:schemas-upnp-org:service:AVTransport:1"
    public static let renderingControl = "urn:schemas-upnp-org:service:RenderingControl:1"

    /// Sends M-SEARCH requests for `targets` and collects unique responses for `timeout` seconds.
    public static func search(targets: [String], timeout: TimeInterval = 3) async -> [SSDPResponse] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: searchBlocking(targets: targets, timeout: timeout))
            }
        }
    }

    static func searchBlocking(targets: [String], timeout: TimeInterval) -> [SSDPResponse] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            Log.discovery.error("SSDP socket failed: \(errno)")
            return []
        }
        defer { Darwin.close(fd) }
        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var ttl: UInt8 = 4
        _ = setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(1900).bigEndian
        address.sin_addr.s_addr = inet_addr("239.255.255.250")

        for target in targets {
            let message = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \(target)\r\n"
                + "USER-AGENT: Darwin UPnP/1.1 MuurMusic/1.0\r\n\r\n"
            let bytes = Array(message.utf8)
            for _ in 0..<2 {
                let sent = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                        sendto(fd, bytes, bytes.count, 0, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if sent < 0 { Log.discovery.error("SSDP send failed: \(errno)") }
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 8192)
        var results: [String: SSDPResponse] = [:]
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(max(1, remaining * 1000)))
            if ready < 0 && errno == EINTR { continue }
            if ready <= 0 { break }
            let capacity = buffer.count
            let count = recv(fd, &buffer, capacity, 0)
            guard count > 0 else { continue }
            let text = String(decoding: buffer[0..<count], as: UTF8.self)
            if let response = SSDPResponse(text) {
                results[response.usn.isEmpty ? response.location.absoluteString : response.usn] = response
            }
        }
        return Array(results.values)
    }
}

// MARK: - Device description

public struct UPnPService: Hashable, Sendable {
    public var serviceType: String
    public var serviceID: String
    public var controlURL: URL
    public var eventSubURL: URL?
    public var scpdURL: URL?
}

/// A UPnP device parsed from its description XML (embedded devices flattened into `services`).
public struct UPnPDevice: Hashable, Sendable, Identifiable {
    public var id: String { udn.isEmpty ? descriptionURL.absoluteString : udn }
    public var descriptionURL: URL
    public var friendlyName: String
    public var deviceType: String
    public var manufacturer: String
    public var modelName: String
    public var udn: String
    public var iconURL: URL?
    public var services: [UPnPService]

    public func service(_ typePrefix: String) -> UPnPService? {
        let base = typePrefix.split(separator: ":").dropLast().joined(separator: ":")
        return services.first { $0.serviceType == typePrefix } ?? services.first { $0.serviceType.hasPrefix(base + ":") }
    }

    public var isMediaServer: Bool { service(SSDPDiscovery.contentDirectory) != nil }
    public var isMediaRenderer: Bool { service(SSDPDiscovery.avTransport) != nil }

    /// Downloads and parses a device description.
    public static func load(from url: URL, http: HTTPClient = .shared) async throws -> UPnPDevice {
        let data = try await http.data(from: url)
        return try parse(data, descriptionURL: url)
    }

    public static func parse(_ data: Data, descriptionURL: URL) throws -> UPnPDevice {
        let root = try XMLTree.parse(data)
        guard let device = root.child("device") else { throw MuurError.invalidData("No <device> in UPnP description") }
        let base = root.childText("URLBase").flatMap(URL.init(string:)) ?? descriptionURL
        func resolve(_ text: String?) -> URL? {
            guard let text, !text.isEmpty else { return nil }
            return URL(string: text, relativeTo: base)?.absoluteURL
        }
        var services: [UPnPService] = []
        func collect(_ node: XNode) {
            for service in node.child("serviceList")?.children("service") ?? [] {
                guard let type = service.childText("serviceType"), let control = resolve(service.childText("controlURL")) else { continue }
                services.append(UPnPService(serviceType: type, serviceID: service.childText("serviceId") ?? "", controlURL: control,
                                            eventSubURL: resolve(service.childText("eventSubURL")), scpdURL: resolve(service.childText("SCPDURL"))))
            }
            for child in node.child("deviceList")?.children("device") ?? [] { collect(child) }
        }
        collect(device)
        let icon = (device.child("iconList")?.children("icon") ?? [])
            .sorted { (Int($0.childText("width") ?? "") ?? 0) > (Int($1.childText("width") ?? "") ?? 0) }
            .first { ($0.childText("mimetype") ?? "").contains("png") || ($0.childText("mimetype") ?? "").contains("jpeg") }
        return UPnPDevice(descriptionURL: descriptionURL, friendlyName: device.childText("friendlyName") ?? descriptionURL.host ?? "UPnP Device",
                          deviceType: device.childText("deviceType") ?? "", manufacturer: device.childText("manufacturer") ?? "",
                          modelName: device.childText("modelName") ?? "", udn: device.childText("UDN") ?? "",
                          iconURL: resolve(icon?.childText("url")), services: services)
    }

    /// Discovers devices of the given SSDP type and loads their descriptions.
    public static func discover(type: String, timeout: TimeInterval = 3, http: HTTPClient = .shared) async -> [UPnPDevice] {
        let responses = await SSDPDiscovery.search(targets: [type], timeout: timeout)
        let locations = Set(responses.map(\.location))
        return await withTaskGroup(of: UPnPDevice?.self) { group in
            for location in locations {
                group.addTask { try? await UPnPDevice.load(from: location, http: http) }
            }
            var devices: [UPnPDevice] = []
            for await device in group {
                if let device { devices.append(device) }
            }
            return devices.sorted { $0.friendlyName.localizedLowercase < $1.friendlyName.localizedLowercase }
        }
    }
}

// MARK: - SOAP

public enum UPnPSOAP {
    /// Invokes an action and returns the response arguments.
    public static func call(_ action: String, service: UPnPService, arguments: [(String, String)] = [],
                            http: HTTPClient = .shared, timeout: TimeInterval = 20) async throws -> [String: String] {
        let args = arguments.map { "<\($0.0)>\(XMLTree.escape($0.1))</\($0.0)>" }.joined()
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:\(action) xmlns:u="\(service.serviceType)">\(args)</u:\(action)></s:Body></s:Envelope>
        """
        var request = URLRequest(url: service.controlURL, method: "POST", headers: [
            "Content-Type": "text/xml; charset=\"utf-8\"",
            "SOAPACTION": "\"\(service.serviceType)#\(action)\"",
        ], body: Data(body.utf8))
        request.timeoutInterval = timeout
        let (data, response) = try await http.data(for: request, validate: false)
        let root = try? XMLTree.parse(data)
        guard (200..<300).contains(response.statusCode) else {
            if let fault = root?.firstDescendant("UPnPError") {
                let code = fault.childText("errorCode") ?? "?"
                let description = fault.childText("errorDescription") ?? "UPnP error"
                throw MuurError.protocolError("\(action) failed (\(code)): \(description)")
            }
            throw MuurError.http(status: response.statusCode, message: action)
        }
        guard let responseNode = root?.firstDescendant(action + "Response") else { return [:] }
        var values: [String: String] = [:]
        for child in responseNode.children { values[child.name] = child.text }
        return values
    }
}

// MARK: - DIDL-Lite

/// A container or item from a ContentDirectory Browse/Search result.
public struct DIDLObject: Hashable, Sendable {
    public var id: String
    public var parentID: String
    public var isContainer: Bool
    public var upnpClass: String
    public var title: String
    public var artist: String
    public var albumArtist: String
    public var album: String
    public var genre: String
    public var trackNumber: Int?
    public var year: Int?
    public var childCount: Int?
    public var albumArtURL: URL?
    public var resourceURL: URL?
    public var mimeType: String?
    public var duration: Double
    public var size: Int64?
    /// kbit/s.
    public var bitrate: Int
    public var sampleRate: Double
    public var bitDepth: Int
    public var channels: Int

    public var isAudio: Bool { upnpClass.hasPrefix("object.item.audioItem") || (mimeType ?? "").hasPrefix("audio/") }
}

public enum DIDLParser {
    public static func parse(_ xml: String) -> [DIDLObject] {
        guard let root = try? XMLTree.parse(xml) else { return [] }
        return root.children.compactMap { node in
            let isContainer = node.name.caseInsensitiveCompare("container") == .orderedSame
            guard isContainer || node.name.caseInsensitiveCompare("item") == .orderedSame else { return nil }
            var object = DIDLObject(id: node.attributes["id"] ?? "", parentID: node.attributes["parentID"] ?? "", isContainer: isContainer,
                                    upnpClass: node.childText("class") ?? "", title: node.childText("title") ?? "", artist: "",
                                    albumArtist: "", album: node.childText("album") ?? "", genre: node.childText("genre") ?? "",
                                    trackNumber: node.childText("originalTrackNumber").flatMap { Int($0) },
                                    year: DateParsing.year(from: node.childText("date")),
                                    childCount: node.attributes["childCount"].flatMap { Int($0) },
                                    albumArtURL: node.childText("albumArtURI").flatMap(URL.init(string:)), resourceURL: nil,
                                    mimeType: nil, duration: 0, size: nil, bitrate: 0, sampleRate: 0, bitDepth: 0, channels: 0)
            for artist in node.children("artist") {
                let role = artist.attributes["role"]?.lowercased() ?? ""
                if role == "albumartist" {
                    if object.albumArtist.isEmpty { object.albumArtist = artist.trimmedText }
                } else if object.artist.isEmpty {
                    object.artist = artist.trimmedText
                }
            }
            if object.artist.isEmpty { object.artist = node.childText("creator") ?? "" }
            let resources = node.children("res").filter { ($0.attributes["protocolInfo"] ?? "").lowercased().hasPrefix("http-get") }
            let preferred = resources.first { ($0.attributes["protocolInfo"] ?? "").contains("audio/") } ?? resources.first
            if let res = preferred {
                object.resourceURL = URL(string: res.trimmedText)
                let info = (res.attributes["protocolInfo"] ?? "").split(separator: ":", omittingEmptySubsequences: false)
                if info.count > 2 { object.mimeType = String(info[2]) }
                object.duration = res.attributes["duration"].map(parseDuration) ?? 0
                object.size = res.attributes["size"].flatMap { Int64($0) }
                object.bitrate = res.attributes["bitrate"].flatMap { Int($0) }.map { $0 * 8 / 1000 } ?? 0
                object.sampleRate = res.attributes["sampleFrequency"].flatMap { Double($0) } ?? 0
                object.bitDepth = res.attributes["bitsPerSample"].flatMap { Int($0) } ?? 0
                object.channels = res.attributes["nrAudioChannels"].flatMap { Int($0) } ?? 0
            }
            return object
        }
    }

    /// "H+:MM:SS[.F+]" or "H+:MM:SS[.F0/F1]" to seconds.
    public static func parseDuration(_ text: String) -> Double {
        let parts = text.split(separator: ":")
        guard parts.count == 3 else { return Double(text) ?? 0 }
        let hours = Double(parts[0]) ?? 0
        let minutes = Double(parts[1]) ?? 0
        var secondsText = String(parts[2])
        if let slash = secondsText.firstIndex(of: "/"), let dot = secondsText.firstIndex(of: ".") {
            let whole = Double(secondsText[..<dot]) ?? 0
            let numerator = Double(secondsText[secondsText.index(after: dot)..<slash]) ?? 0
            let denominator = Double(secondsText[secondsText.index(after: slash)...]) ?? 1
            return hours * 3600 + minutes * 60 + whole + (denominator > 0 ? numerator / denominator : 0)
        }
        if secondsText.isEmpty { secondsText = "0" }
        return hours * 3600 + minutes * 60 + (Double(secondsText) ?? 0)
    }

    /// Seconds to "H:MM:SS".
    public static func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    /// Minimal DIDL-Lite metadata for AVTransport `SetAVTransportURI`.
    public static func metadata(title: String, artist: String, album: String, url: URL, mimeType: String, duration: Double,
                                albumArtURL: URL? = nil) -> String {
        let art = albumArtURL.map { "<upnp:albumArtURI>\(XMLTree.escape($0.absoluteString))</upnp:albumArtURI>" } ?? ""
        return "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" "
            + "xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\"><item id=\"muur-0\" parentID=\"0\" restricted=\"1\">"
            + "<dc:title>\(XMLTree.escape(title))</dc:title><dc:creator>\(XMLTree.escape(artist))</dc:creator>"
            + "<upnp:artist>\(XMLTree.escape(artist))</upnp:artist><upnp:album>\(XMLTree.escape(album))</upnp:album>\(art)"
            + "<upnp:class>object.item.audioItem.musicTrack</upnp:class>"
            + "<res protocolInfo=\"http-get:*:\(mimeType):*\" duration=\"\(formatDuration(duration))\">\(XMLTree.escape(url.absoluteString))</res>"
            + "</item></DIDL-Lite>"
    }
}

// MARK: - Source

/// DLNA / UPnP media servers (ContentDirectory browsing).
///
/// `config.option(upnpDescriptionURL)`: device description URL (from discovery or entered manually,
/// e.g. `http://192.168.1.10:8200/rootDesc.xml`). URIs: `upnp://<sourceId>/<objectId>`.
public final class UPnPSource: MusicSource {
    public let config: SourceConfig
    public var capabilities: SourceCapabilities { [.browse, .search, .directURL, .library] }
    private let http: HTTPClient
    private let descriptionURL: URL
    private let device = LockedValue<UPnPDevice?>(nil)
    private let resources = LockedValue<[String: DIDLObject]>([:])

    public init(config: SourceConfig) throws {
        self.config = config
        let text = config.option(SourceConfig.OptionKey.upnpDescriptionURL) ?? config.host
        guard let url = URL(string: text), url.scheme?.hasPrefix("http") == true else {
            throw MuurError.notConfigured("DLNA device description URL")
        }
        descriptionURL = url
        http = HTTPClient(allowInsecureTLS: true)
    }

    private func contentDirectory() async throws -> UPnPService {
        if let cached = device.get(), let service = cached.service(SSDPDiscovery.contentDirectory) { return service }
        let loaded = try await UPnPDevice.load(from: descriptionURL, http: http)
        device.set(loaded)
        guard let service = loaded.service(SSDPDiscovery.contentDirectory) else {
            throw MuurError.unsupported("\(loaded.friendlyName) is not a media server; browsing")
        }
        return service
    }

    public func connect() async throws {
        _ = try await contentDirectory()
    }

    private func uri(for objectID: String) -> String {
        SourceURI(scheme: "upnp", authority: config.id.uuidString, path: objectID).description
    }

    private func browse(_ objectID: String, flag: String = "BrowseDirectChildren") async throws -> [DIDLObject] {
        let service = try await contentDirectory()
        var objects: [DIDLObject] = []
        var start = 0
        while true {
            try Task.checkCancellation()
            let result = try await UPnPSOAP.call("Browse", service: service, arguments: [
                ("ObjectID", objectID), ("BrowseFlag", flag), ("Filter", "*"), ("StartingIndex", String(start)),
                ("RequestedCount", "500"), ("SortCriteria", ""),
            ], http: http)
            let page = DIDLParser.parse(result["Result"] ?? "")
            objects.append(contentsOf: page)
            let returned = Int(result["NumberReturned"] ?? "") ?? page.count
            let total = Int(result["TotalMatches"] ?? "") ?? 0
            start += returned
            if flag != "BrowseDirectChildren" || returned == 0 || (total > 0 && start >= total) || (total == 0 && page.isEmpty) { break }
        }
        remember(objects)
        return objects
    }

    private func remember(_ objects: [DIDLObject]) {
        resources.mutate { cache in
            for object in objects where !object.isContainer { cache[object.id] = object }
            if cache.count > 20_000 { cache.removeAll() }
        }
    }

    private func item(for object: DIDLObject) -> SourceItem {
        if object.isContainer {
            return SourceItem(uri: uri(for: object.id), name: object.title, kind: .folder, path: object.id,
                              artworkURL: object.albumArtURL, childCount: object.childCount,
                              subtitle: object.artist.isEmpty ? nil : object.artist)
        }
        let fileName = object.resourceURL?.lastPathComponent ?? object.title
        let track = makeTrack(object)
        return SourceItem(uri: uri(for: object.id), name: object.title, kind: object.isAudio ? .audio : SourceItem.kind(forFileName: fileName),
                          path: object.id, size: object.size, mimeType: object.mimeType, track: object.isAudio ? track : nil,
                          artworkURL: object.albumArtURL, subtitle: object.artist.isEmpty ? nil : object.artist)
    }

    private func makeTrack(_ object: DIDLObject) -> Track {
        let ext = object.resourceURL.map { PathUtils.fileExtension($0.lastPathComponent) } ?? ""
        let codecExt = ext.isEmpty ? (object.mimeType.map(UPnPSource.extensionForMime) ?? "") : ext
        var track = Track(sourceURI: uri(for: object.id), sourceID: config.id.uuidString, folderPath: config.name,
                          fileName: object.title + (codecExt.isEmpty ? "" : "." + codecExt), title: object.title,
                          artist: object.artist, album: object.album, albumArtist: object.albumArtist, genre: object.genre,
                          year: object.year, trackNumber: object.trackNumber, duration: object.duration, bitrate: object.bitrate,
                          sampleRate: object.sampleRate, bitDepth: object.bitDepth, channels: object.channels,
                          fileSize: object.size ?? 0)
        track.codec = MetadataReader.normalizeCodec(nil, fileExtension: codecExt)
        return track
    }

    static func extensionForMime(_ mime: String) -> String {
        switch mime.lowercased() {
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/flac", "audio/x-flac": return "flac"
        case "audio/mp4", "audio/x-m4a", "audio/aac": return "m4a"
        case "audio/wav", "audio/x-wav", "audio/wave": return "wav"
        case "audio/aiff", "audio/x-aiff": return "aiff"
        case "audio/ogg", "application/ogg": return "ogg"
        case "audio/x-ms-wma": return "wma"
        case "audio/x-dsf", "audio/dsf": return "dsf"
        case "audio/x-dff", "audio/dff": return "dff"
        case "audio/x-ape", "audio/ape": return "ape"
        case "audio/x-wavpack": return "wv"
        default: return ""
        }
    }

    public func list(_ container: SourceItem?) async throws -> [SourceItem] {
        let objects = try await browse(container?.path ?? "0")
        return objects.map(item(for:))
    }

    public func search(_ text: String) async throws -> [SourceItem] {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let criteria = "(dc:title contains \"\(escaped)\" or upnp:artist contains \"\(escaped)\" or upnp:album contains \"\(escaped)\")"
        return try await searchObjects(criteria, limit: 300).map(item(for:))
    }

    private func searchObjects(_ criteria: String, limit: Int, progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> [DIDLObject] {
        let service = try await contentDirectory()
        var objects: [DIDLObject] = []
        var start = 0
        while objects.count < limit {
            try Task.checkCancellation()
            let result = try await UPnPSOAP.call("Search", service: service, arguments: [
                ("ContainerID", "0"), ("SearchCriteria", criteria), ("Filter", "*"), ("StartingIndex", String(start)),
                ("RequestedCount", "500"), ("SortCriteria", ""),
            ], http: http, timeout: 60)
            let page = DIDLParser.parse(result["Result"] ?? "")
            objects.append(contentsOf: page)
            let returned = Int(result["NumberReturned"] ?? "") ?? page.count
            let total = Int(result["TotalMatches"] ?? "") ?? 0
            start += returned
            progress?(objects.count, total)
            if returned == 0 || (total > 0 && start >= total) { break }
        }
        remember(objects)
        return objects
    }

    public func libraryTracks(progress: @escaping @Sendable (Int, Int) -> Void) async throws -> [Track]? {
        let objects: [DIDLObject]
        do {
            objects = try await searchObjects("upnp:class derivedfrom \"object.item.audioItem\"", limit: 200_000, progress: progress)
        } catch {
            // Servers without Search support: walk the tree.
            var collected: [DIDLObject] = []
            var stack = ["0"]
            var visited = 0
            while let next = stack.popLast(), visited < 5000 {
                visited += 1
                let children = try await browse(next)
                for child in children {
                    if child.isContainer { stack.append(child.id) } else if child.isAudio { collected.append(child) }
                }
                progress(collected.count, 0)
            }
            objects = collected
        }
        var seen = Set<String>()
        return objects.filter { $0.isAudio && $0.resourceURL != nil && seen.insert($0.id).inserted }.map { makeTrack($0) }
    }

    private func object(for uri: String) async throws -> DIDLObject {
        guard let parsed = SourceURI.parse(uri), parsed.scheme == "upnp" else { throw MuurError.invalidData("Not a UPnP URI") }
        if let cached = resources.get()[parsed.path], cached.resourceURL != nil { return cached }
        guard let object = try await browse(parsed.path, flag: "BrowseMetadata").first, object.resourceURL != nil else {
            throw MuurError.notFound(uri)
        }
        return object
    }

    public func streamURL(for uri: String) async throws -> RemoteResource? {
        guard let url = try await object(for: uri).resourceURL else { return nil }
        return RemoteResource(url: url)
    }

    public func download(uri: String, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        guard let url = try await object(for: uri).resourceURL else { throw MuurError.notFound(uri) }
        try await http.download(URLRequest(url: url), to: destination, progress: progress)
    }
}
