import Foundation
import Network
import ZIPFoundation
#if canImport(UIKit)
import UIKit
#endif
#if os(macOS)
import SystemConfiguration
#endif

/// One upload shown in the app while the Wi-Fi transfer server is running.
public struct WiFiTransferUpload: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var fileName: String
    public var bytesReceived: Int64
    public var bytesExpected: Int64
    public var isFinished: Bool
    public var errorMessage: String?
    public var startedAt: Date

    public init(id: UUID, fileName: String, bytesReceived: Int64 = 0, bytesExpected: Int64 = 0, isFinished: Bool = false,
                errorMessage: String? = nil, startedAt: Date = Date()) {
        self.id = id
        self.fileName = fileName
        self.bytesReceived = bytesReceived
        self.bytesExpected = bytesExpected
        self.isFinished = isFinished
        self.errorMessage = errorMessage
        self.startedAt = startedAt
    }

    public var fraction: Double {
        bytesExpected > 0 ? min(1, Double(bytesReceived) / Double(bytesExpected)) : (isFinished ? 1 : 0)
    }
}

/// Events reported by connections (on the server queue) to the main-actor server object.
enum WiFiTransferEvent: Sendable {
    case started(UUID, String, Int64)
    case progress(UUID, Int64)
    case finished(UUID, URL)
    case failed(UUID, String)
    case deleted(URL)
}

/// An HTTP server on the local network that lets a browser upload music into the app's music folder
/// (FEATURES "Wi-Fi transfer"). Serves a cat-themed upload page with drag & drop, folder upload,
/// per-file progress, a file list with download/delete, and an optional PIN.
///
/// Uploaded ZIP archives are extracted. `onFilesReceived` fires (debounced) after uploads so the app can
/// rescan the library (`MuurEnvironment` wires it to the scanner). iOS suspends the listener when the app
/// goes to the background; keep the transfer screen visible while uploading.
@MainActor
public final class WiFiTransferServer: ObservableObject {
    @Published public private(set) var isRunning = false
    @Published public private(set) var port: UInt16 = 0
    /// Addresses to type into a browser, e.g. `http://192.168.1.20:8080/`.
    @Published public private(set) var urls: [URL] = []
    @Published public private(set) var uploads: [WiFiTransferUpload] = []
    @Published public private(set) var receivedFileCount = 0
    @Published public private(set) var lastError: String?

    /// Called on the main actor about two seconds after the last completed upload, with the new files.
    public var onFilesReceived: (@MainActor ([URL]) -> Void)?

    public let paths: AppPaths
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "app.muur.wifi-transfer", qos: .userInitiated)
    private var listener: NWListener?
    private var context: WiFiTransferContext?
    private var pendingFiles: [URL] = []
    private var notifyTask: Task<Void, Never>?
    private var lastProgressPublish: [UUID: Date] = [:]
    private var retriedWithAnyPort = false

    public init(paths: AppPaths, defaults: UserDefaults = .standard) {
        self.paths = paths
        self.defaults = defaults
    }

    /// The PIN required by the page when `wifiTransferRequirePIN` is on.
    public var pin: String { defaults.string(forKey: MuurSettings.Key.wifiTransferPIN.rawValue) ?? "" }
    public var requiresPIN: Bool { defaults.bool(forKey: MuurSettings.Key.wifiTransferRequirePIN.rawValue) }

    /// Starts listening on `port` (default: the `wifiTransferPort` setting, 8080). If the port is taken,
    /// the server falls back to a free port chosen by the system.
    public func start(port requestedPort: Int? = nil) throws {
        stop()
        retriedWithAnyPort = false
        let key = MuurSettings.Key.wifiTransferPort.rawValue
        let settingsPort = defaults.object(forKey: key) == nil ? 8080 : defaults.integer(forKey: key)
        try startListener(port: UInt16(clamping: max(0, requestedPort ?? settingsPort)))
    }

    private func startListener(port: UInt16) throws {
        let requirePIN = requiresPIN
        let currentPIN = pin
        if requirePIN && currentPIN.isEmpty {
            throw MuurError.notConfigured("Wi-Fi transfer PIN")
        }
        try FileManager.default.createDirectory(at: paths.musicFolder, withIntermediateDirectories: true)
        let context = WiFiTransferContext(root: paths.musicFolder, requirePIN: requirePIN, pin: currentPIN,
                                          deviceName: WiFiTransferServer.deviceName()) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        let newListener: NWListener
        if port != 0, let endpointPort = NWEndpoint.Port(rawValue: port) {
            newListener = try NWListener(using: parameters, on: endpointPort)
        } else {
            newListener = try NWListener(using: parameters)
        }
        let queue = self.queue
        let identity = ObjectIdentifier(newListener)
        newListener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, let current = self.listener, ObjectIdentifier(current) == identity else { return }
                self.listenerStateChanged(state)
            }
        }
        newListener.newConnectionHandler = { connection in
            let handler = TransferConnection(connection: connection, context: context, queue: queue)
            handler.start()
        }
        self.context = context
        self.listener = newListener
        lastError = nil
        newListener.start(queue: queue)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        context?.closeAll()
        context = nil
        isRunning = false
        port = 0
        urls = []
    }

    /// Clears finished entries from `uploads`.
    public func clearFinishedUploads() {
        uploads.removeAll { $0.isFinished }
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            isRunning = true
            port = listener?.port?.rawValue ?? 0
            refreshURLs()
            Log.transfer.info("Wi-Fi transfer listening on port \(self.port)")
        case .failed(let error):
            isRunning = false
            if case .posix(let code) = error, code == .EADDRINUSE, !retriedWithAnyPort {
                retriedWithAnyPort = true
                listener?.cancel()
                listener = nil
                do {
                    try startListener(port: 0)
                    return
                } catch {
                    lastError = error.localizedDescription
                }
            }
            lastError = error.localizedDescription
            Log.transfer.error("Wi-Fi transfer failed: \(error.localizedDescription, privacy: .public)")
            listener?.cancel()
            listener = nil
        case .cancelled:
            isRunning = false
        default:
            break
        }
    }

    /// Re-reads the device's network addresses (call when the Wi-Fi network changes).
    public func refreshURLs() {
        guard port != 0 else {
            urls = []
            return
        }
        urls = WiFiTransferServer.localIPv4Addresses().compactMap { URL(string: "http://\($0):\(port)/") }
    }

    private func handle(_ event: WiFiTransferEvent) {
        switch event {
        case .started(let id, let name, let expected):
            uploads.insert(WiFiTransferUpload(id: id, fileName: name, bytesExpected: expected), at: 0)
            if uploads.count > 200 { uploads.removeLast(uploads.count - 200) }
        case .progress(let id, let received):
            let now = Date()
            if let last = lastProgressPublish[id], now.timeIntervalSince(last) < 0.2 { return }
            lastProgressPublish[id] = now
            if let index = uploads.firstIndex(where: { $0.id == id }) { uploads[index].bytesReceived = received }
        case .finished(let id, let url):
            lastProgressPublish[id] = nil
            if let index = uploads.firstIndex(where: { $0.id == id }) {
                uploads[index].isFinished = true
                uploads[index].bytesReceived = max(uploads[index].bytesReceived, uploads[index].bytesExpected)
            }
            receivedFileCount += 1
            if PathUtils.isArchive(url.lastPathComponent) {
                extractArchive(url)
            } else {
                fileArrived(url)
            }
        case .failed(let id, let message):
            lastProgressPublish[id] = nil
            if let index = uploads.firstIndex(where: { $0.id == id }) {
                uploads[index].isFinished = true
                uploads[index].errorMessage = message
            }
        case .deleted:
            scheduleNotification()
        }
    }

    private func extractArchive(_ url: URL) {
        Task { [weak self] in
            let result: Result<URL, Error> = await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                var target = url.deletingPathExtension()
                var counter = 2
                while fm.fileExists(atPath: target.path) {
                    target = url.deletingLastPathComponent().appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) \(counter)")
                    counter += 1
                }
                do {
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                    try fm.unzipItem(at: url, to: target)
                    try? fm.removeItem(at: target.appendingPathComponent("__MACOSX"))
                    try fm.removeItem(at: url)
                    return .success(target)
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self else { return }
            switch result {
            case .success(let folder): self.fileArrived(folder)
            case .failure(let error):
                self.lastError = "\(url.lastPathComponent): \(error.localizedDescription)"
                self.fileArrived(url)
            }
        }
    }

    private func fileArrived(_ url: URL) {
        pendingFiles.append(url)
        scheduleNotification()
    }

    private func scheduleNotification() {
        notifyTask?.cancel()
        notifyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            let files = self.pendingFiles
            self.pendingFiles.removeAll()
            self.onFilesReceived?(files)
        }
    }

    private static func deviceName() -> String {
        #if os(macOS)
        return (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
        #elseif canImport(UIKit)
        return UIDevice.current.name
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }

    /// IPv4 addresses of Wi-Fi / Ethernet interfaces (cellular and VPN interfaces are skipped).
    public nonisolated static func localIPv4Addresses() -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let interface = current.pointee
            cursor = interface.ifa_next
            let flags = Int32(interface.ifa_flags)
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") || name.hasPrefix("ap") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            guard status == 0 else { continue }
            let ip = host.withUnsafeBufferPointer { buffer in String(cString: buffer.baseAddress!) }
            if !result.contains(ip) { result.append(ip) }
        }
        return result
    }
}

// MARK: - Shared state

/// Thread-safe state shared by all connections of one server run.
final class WiFiTransferContext: @unchecked Sendable {
    let root: URL
    let requirePIN: Bool
    let pin: String
    let deviceName: String
    let emit: @Sendable (WiFiTransferEvent) -> Void
    private let sessions = LockedValue<Set<String>>([])
    private let failures = LockedValue<[String: (count: Int, lockedUntil: Date?)]>([:])
    private let connections = LockedValue<[ObjectIdentifier: TransferConnection]>([:])

    init(root: URL, requirePIN: Bool, pin: String, deviceName: String, emit: @escaping @Sendable (WiFiTransferEvent) -> Void) {
        self.root = root.standardizedFileURL
        self.requirePIN = requirePIN
        self.pin = pin
        self.deviceName = deviceName
        self.emit = emit
    }

    func register(_ connection: TransferConnection) {
        connections.mutate { $0[ObjectIdentifier(connection)] = connection }
    }

    func unregister(_ connection: TransferConnection) {
        connections.mutate { $0[ObjectIdentifier(connection)] = nil }
    }

    func closeAll() {
        let all = connections.mutate { map -> [TransferConnection] in
            let values = Array(map.values)
            map.removeAll()
            return values
        }
        for connection in all { connection.cancel() }
    }

    func isAuthorized(_ head: HTTPRequestHead) -> Bool {
        guard requirePIN else { return true }
        if let header = head.headers["x-muur-pin"], WiFiTransferContext.constantTimeEquals(header, pin) { return true }
        if let token = head.cookie("muur_session"), sessions.get().contains(token) { return true }
        return false
    }

    enum LoginResult {
        case success(token: String)
        case wrongPIN
        case lockedOut(seconds: Int)
    }

    func login(pin candidate: String, remote: String) -> LoginResult {
        let now = Date()
        if let lockedUntil = failures.get()[remote]?.lockedUntil, lockedUntil > now {
            return .lockedOut(seconds: Int(lockedUntil.timeIntervalSince(now).rounded(.up)))
        }
        if WiFiTransferContext.constantTimeEquals(candidate.trimmingCharacters(in: .whitespaces), pin) {
            failures.mutate { $0[remote] = nil }
            let token = Hashing.base64URL(Hashing.randomBytes(24))
            sessions.mutate { $0.insert(token) }
            return .success(token: token)
        }
        let locked = failures.mutate { map -> Int? in
            var entry = map[remote] ?? (0, nil)
            entry.count += 1
            if entry.count >= 5 {
                entry = (0, now.addingTimeInterval(60))
                map[remote] = entry
                return 60
            }
            map[remote] = entry
            return nil
        }
        if let locked { return .lockedOut(seconds: locked) }
        return .wrongPIN
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<a.count { difference |= a[index] ^ b[index] }
        return difference == 0
    }

    /// Validates a client-supplied relative path ("Album/01 Song.flac"): no parent references, sanitized components.
    static func safeRelativePath(_ raw: String) -> String? {
        let components = raw.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
            .filter { !$0.isEmpty && $0 != "." }
        guard !components.isEmpty, !components.contains("..") else { return nil }
        return components.map(PathUtils.sanitizeFileName).joined(separator: "/")
    }

    /// Resolves a relative path inside the root (nil when it escapes the root).
    func resolve(_ relative: String) -> URL? {
        guard let safe = WiFiTransferContext.safeRelativePath(relative) else { return nil }
        let url = root.appendingPathComponent(safe).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else { return nil }
        return url
    }

    static let allowedUploadExtensions: Set<String> = PathUtils.audioExtensions
        .union(PathUtils.playlistExtensions).union(PathUtils.archiveExtensions)
        .union(PathUtils.imageExtensions).union(PathUtils.lyricsExtensions).union(["json", "pls"])

    static func isAllowedUpload(_ name: String) -> Bool {
        allowedUploadExtensions.contains(PathUtils.fileExtension(name))
    }

    var freeBytes: Int64 {
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? -1
    }
}

// MARK: - HTTP

struct HTTPRequestHead {
    var method: String
    var path: String
    var query: [String: String]
    /// Lowercased header names.
    var headers: [String: String]

    static func parse(_ data: Data) -> HTTPRequestHead? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { return nil }
        let target = String(requestLine[1])
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = parts.isEmpty ? "/" : String(parts[0])
        let path = rawPath.removingPercentEncoding ?? rawPath
        var query: [String: String] = [:]
        if parts.count > 1 { query = HTTPRequestHead.decodeForm(String(parts[1])) }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return HTTPRequestHead(method: String(requestLine[0]).uppercased(), path: path, query: query, headers: headers)
    }

    static func decodeForm(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(kv[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(kv[0])
            let value = kv.count > 1 ? (String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(kv[1])) : ""
            result[key] = value
        }
        return result
    }

    var contentLength: Int64? { headers["content-length"].flatMap { Int64($0) } }

    func cookie(_ name: String) -> String? {
        guard let header = headers["cookie"] else { return nil }
        for part in header.split(separator: ";") {
            let kv = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            if kv.count == 2 && kv[0] == name { return String(kv[1]) }
        }
        return nil
    }

    var wantsHTML: Bool { (headers["accept"] ?? "").contains("text/html") }
}

/// Writes one uploaded file to a temporary name and moves it into place when complete.
final class UploadFileSink {
    let id = UUID()
    let displayName: String
    private let directory: URL
    private let fileName: String
    private let temporaryURL: URL
    private let handle: FileHandle
    private let context: WiFiTransferContext
    private(set) var written: Int64 = 0
    private var lastReported: Int64 = 0

    init(relativePath: String, expected: Int64, context: WiFiTransferContext) throws {
        guard let target = context.resolve(relativePath) else { throw MuurError.invalidData("Invalid file name") }
        self.context = context
        self.directory = target.deletingLastPathComponent()
        self.fileName = target.lastPathComponent
        self.displayName = relativePath
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryURL = directory.appendingPathComponent("." + UUID().uuidString + ".muurpart")
        guard fm.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw MuurError.io("Cannot create \(fileName)")
        }
        handle = try FileHandle(forWritingTo: temporaryURL)
        context.emit(.started(id, relativePath, expected))
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        try handle.write(contentsOf: data)
        written += Int64(data.count)
        if written - lastReported >= 512 * 1024 {
            lastReported = written
            context.emit(.progress(id, written))
        }
    }

    /// Finishes the file, picking a unique name ("Song 2.mp3") when the name exists. Returns the final URL.
    @discardableResult
    func finish() throws -> URL {
        try handle.close()
        let fm = FileManager.default
        var target = directory.appendingPathComponent(fileName)
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var counter = 2
        while fm.fileExists(atPath: target.path) {
            target = directory.appendingPathComponent(ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)")
            counter += 1
        }
        try fm.moveItem(at: temporaryURL, to: target)
        context.emit(.progress(id, written))
        context.emit(.finished(id, target))
        return target
    }

    func abort(_ message: String) {
        try? handle.close()
        try? FileManager.default.removeItem(at: temporaryURL)
        context.emit(.failed(id, message))
    }
}

/// Streaming `multipart/form-data` parser that writes file parts straight to disk.
final class MultipartUploadParser {
    private enum Phase { case preamble, afterBoundary, headers, data, done }

    private let dashBoundary: Data
    private let delimiter: Data
    private let context: WiFiTransferContext
    private var buffer = Data()
    private var phase = Phase.preamble
    private var currentSink: UploadFileSink?
    private var currentField: String?
    private var fieldValue = Data()
    private(set) var fields: [String: String] = [:]
    private(set) var files: [URL] = []
    private(set) var rejected: [String] = []

    init(boundary: String, context: WiFiTransferContext) {
        dashBoundary = Data(("--" + boundary).utf8)
        delimiter = Data(("\r\n--" + boundary).utf8)
        self.context = context
    }

    var isDone: Bool { phase == .done }

    func feed(_ chunk: Data) throws {
        buffer.append(chunk)
        while true {
            switch phase {
            case .preamble:
                guard let range = buffer.range(of: dashBoundary) else {
                    if buffer.count > dashBoundary.count { buffer = Data(buffer.suffix(dashBoundary.count)) }
                    return
                }
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                phase = .afterBoundary
            case .afterBoundary:
                guard buffer.count >= 2 else { return }
                let marker = buffer.prefix(2)
                if marker == Data("--".utf8) {
                    phase = .done
                    buffer.removeAll()
                    return
                }
                guard marker == Data("\r\n".utf8) else { throw MuurError.protocolError("Malformed multipart body") }
                buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + 2))
                phase = .headers
            case .headers:
                guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    if buffer.count > 16 * 1024 { throw MuurError.protocolError("Multipart headers too large") }
                    return
                }
                let headerText = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                try beginPart(headerText)
                phase = .data
            case .data:
                if let range = buffer.range(of: delimiter) {
                    try append(Data(buffer[buffer.startIndex..<range.lowerBound]))
                    buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                    try endPart()
                    phase = .afterBoundary
                } else {
                    let safe = buffer.count - delimiter.count
                    if safe > 0 {
                        try append(Data(buffer.prefix(safe)))
                        buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + safe))
                    }
                    return
                }
            case .done:
                buffer.removeAll()
                return
            }
        }
    }

    private func beginPart(_ headerText: String) throws {
        var name: String?
        var fileName: String?
        for line in headerText.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            guard lower.hasPrefix("content-disposition:") else { continue }
            name = MultipartUploadParser.parameter("name", in: line)
            fileName = MultipartUploadParser.parameter("filename", in: line)
        }
        if let fileName {
            guard !fileName.isEmpty else {
                currentSink = nil
                currentField = nil
                return
            }
            let relative = WiFiTransferContext.safeRelativePath(fileName) ?? PathUtils.sanitizeFileName(fileName)
            guard WiFiTransferContext.isAllowedUpload(relative) else {
                rejected.append(fileName)
                currentSink = nil
                currentField = nil
                return
            }
            let folder = fields["folder"].flatMap(WiFiTransferContext.safeRelativePath)
            currentSink = try UploadFileSink(relativePath: folder.map { $0 + "/" + relative } ?? relative, expected: 0, context: context)
            currentField = nil
        } else {
            currentSink = nil
            currentField = name
            fieldValue = Data()
        }
    }

    private func append(_ data: Data) throws {
        if let currentSink {
            try currentSink.write(data)
        } else if currentField != nil, fieldValue.count < 4096 {
            fieldValue.append(data.prefix(4096 - fieldValue.count))
        }
    }

    private func endPart() throws {
        if let sink = currentSink {
            files.append(try sink.finish())
        } else if let field = currentField {
            fields[field] = String(decoding: fieldValue, as: UTF8.self)
        }
        currentSink = nil
        currentField = nil
    }

    func abort(_ message: String) {
        currentSink?.abort(message)
        currentSink = nil
    }

    static func parameter(_ name: String, in header: String) -> String? {
        for part in header.components(separatedBy: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix(name + "=") else { continue }
            var value = String(trimmed.dropFirst(name.count + 1))
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value.replacingOccurrences(of: "\\\"", with: "\"")
        }
        return nil
    }
}

/// One HTTP connection (one request per connection; responses use `Connection: close`).
/// All callbacks run on the server's serial queue.
final class TransferConnection: @unchecked Sendable {
    private enum Body {
        case none
        case small(Data)
        case raw(UploadFileSink)
        case multipart(MultipartUploadParser)
    }

    private let connection: NWConnection
    private let context: WiFiTransferContext
    private let queue: DispatchQueue
    private var headerBuffer = Data()
    private var head: HTTPRequestHead?
    private var body = Body.none
    private var remaining: Int64 = 0
    private var responded = false
    private var finished = false

    init(connection: NWConnection, context: WiFiTransferContext, queue: DispatchQueue) {
        self.connection = connection
        self.context = context
        self.queue = queue
    }

    func start() {
        context.register(self)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.connectionEnded()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func cancel() {
        connection.cancel()
    }

    private var remoteHost: String {
        if case .hostPort(let host, _) = connection.endpoint { return "\(host)" }
        return "unknown"
    }

    private func connectionEnded() {
        if !finished {
            switch body {
            case .raw(let sink): sink.abort("Connection lost")
            case .multipart(let parser): parser.abort("Connection lost")
            default: break
            }
            finished = true
        }
        context.unregister(self)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.consume(data) }
            if self.responded || self.finished { return }
            if error != nil || isComplete {
                self.connectionEnded()
                self.connection.cancel()
                return
            }
            self.receive()
        }
    }

    private func consume(_ data: Data) {
        guard !responded else { return }
        if head == nil {
            headerBuffer.append(data)
            guard let end = headerBuffer.range(of: Data("\r\n\r\n".utf8)) else {
                if headerBuffer.count > 32 * 1024 { respond(status: 431, reason: "Request Header Fields Too Large") }
                return
            }
            let headData = headerBuffer[headerBuffer.startIndex..<end.lowerBound]
            let rest = Data(headerBuffer[end.upperBound...])
            headerBuffer = Data()
            guard let parsed = HTTPRequestHead.parse(Data(headData)) else {
                respond(status: 400, reason: "Bad Request")
                return
            }
            head = parsed
            beginBody(parsed)
            if responded { return }
            if remaining == 0 {
                finishRequest()
            } else if !rest.isEmpty {
                consumeBody(rest)
            }
        } else {
            consumeBody(data)
        }
    }

    private func beginBody(_ head: HTTPRequestHead) {
        if head.headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            respond(status: 411, reason: "Length Required")
            return
        }
        remaining = max(0, head.contentLength ?? 0)
        let isPublic = (head.method == "GET" && (head.path == "/" || head.path == "/index.html" || head.path == "/favicon.ico"
                                                 || head.path == "/api/info"))
            || (head.method == "POST" && head.path == "/api/login")
        if !isPublic && !context.isAuthorized(head) {
            respondJSON(status: 401, reason: "Unauthorized", ["error": "PIN required"])
            return
        }
        let free = context.freeBytes
        switch (head.method, head.path) {
        case ("POST", "/api/upload"):
            let rawName = head.headers["x-file-name"].flatMap { $0.removingPercentEncoding } ?? head.query["name"] ?? ""
            guard let relative = WiFiTransferContext.safeRelativePath(rawName) else {
                respondJSON(status: 400, reason: "Bad Request", ["error": "Missing or invalid file name"])
                return
            }
            guard WiFiTransferContext.isAllowedUpload(relative) else {
                respondJSON(status: 415, reason: "Unsupported Media Type", ["error": "\(PathUtils.lastComponent(relative)) is not a music, playlist, lyrics, artwork or ZIP file"])
                return
            }
            if free >= 0 && remaining > free {
                respondJSON(status: 507, reason: "Insufficient Storage", ["error": "Not enough free space on the device"])
                return
            }
            do {
                let sink = try UploadFileSink(relativePath: relative, expected: remaining, context: context)
                body = .raw(sink)
            } catch {
                respondJSON(status: 500, reason: "Internal Server Error", ["error": error.localizedDescription])
            }
        case ("POST", "/upload"):
            let contentType = head.headers["content-type"] ?? ""
            guard contentType.lowercased().hasPrefix("multipart/form-data"),
                  let boundary = MultipartUploadParser.parameter("boundary", in: contentType), !boundary.isEmpty else {
                respond(status: 400, reason: "Bad Request")
                return
            }
            if free >= 0 && remaining > free {
                respond(status: 507, reason: "Insufficient Storage", body: Data("Not enough free space on the device".utf8),
                        contentType: "text/plain; charset=utf-8")
                return
            }
            body = .multipart(MultipartUploadParser(boundary: boundary, context: context))
        default:
            if remaining > 64 * 1024 {
                respond(status: 413, reason: "Payload Too Large")
                return
            }
            body = .small(Data())
        }
    }

    private func consumeBody(_ data: Data) {
        let take = Int(min(Int64(data.count), remaining))
        let chunk = take == data.count ? data : Data(data.prefix(take))
        remaining -= Int64(take)
        do {
            switch body {
            case .none: break
            case .small(var buffer):
                buffer.append(chunk)
                body = .small(buffer)
            case .raw(let sink):
                try sink.write(chunk)
            case .multipart(let parser):
                try parser.feed(chunk)
            }
        } catch {
            failUpload(error)
            return
        }
        if remaining == 0 { finishRequest() }
    }

    private func failUpload(_ error: Error) {
        switch body {
        case .raw(let sink): sink.abort(error.localizedDescription)
        case .multipart(let parser): parser.abort(error.localizedDescription)
        default: break
        }
        finished = true
        respondJSON(status: 500, reason: "Internal Server Error", ["error": error.localizedDescription])
    }

    private func finishRequest() {
        guard let head else { return }
        switch body {
        case .raw(let sink):
            do {
                let url = try sink.finish()
                finished = true
                respondJSON(status: 201, reason: "Created", ["ok": true, "path": relativePath(of: url)])
            } catch {
                failUpload(error)
            }
            return
        case .multipart(let parser):
            finished = true
            var message = "Uploaded \(parser.files.count) file(s)."
            if !parser.rejected.isEmpty { message += " Skipped: " + parser.rejected.joined(separator: ", ") }
            if head.wantsHTML {
                respond(status: 303, reason: "See Other", headers: ["Location": "/"])
            } else {
                respondJSON(status: 201, reason: "Created", ["ok": true, "message": message, "files": parser.files.map(relativePath(of:))])
            }
            return
        case .small(let data):
            finished = true
            route(head, body: data)
        case .none:
            finished = true
            route(head, body: Data())
        }
    }

    private func relativePath(of url: URL) -> String {
        let path = url.standardizedFileURL.path
        let root = context.root.path
        return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : url.lastPathComponent
    }

    // MARK: Routes

    private func route(_ head: HTTPRequestHead, body: Data) {
        switch (head.method, head.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            respond(status: 200, reason: "OK", body: Data(WiFiTransferPage.html.utf8), contentType: "text/html; charset=utf-8")
        case ("GET", "/favicon.ico"):
            respond(status: 200, reason: "OK", body: Data(WiFiTransferPage.faviconSVG.utf8), contentType: "image/svg+xml")
        case ("GET", "/api/info"):
            respondJSON(status: 200, reason: "OK", [
                "name": context.deviceName,
                "requiresPIN": context.requirePIN,
                "authorized": context.isAuthorized(head),
                "freeBytes": context.freeBytes,
            ])
        case ("POST", "/api/login"):
            login(head, body: body)
        case ("GET", "/api/files"):
            respondJSON(status: 200, reason: "OK", ["files": listFiles(), "freeBytes": context.freeBytes])
        case ("DELETE", "/api/files"), ("POST", "/api/delete"):
            let form = HTTPRequestHead.decodeForm(String(decoding: body, as: UTF8.self))
            guard let relative = head.query["path"] ?? form["path"], let url = context.resolve(relative) else {
                respondJSON(status: 400, reason: "Bad Request", ["error": "Invalid path"])
                return
            }
            do {
                try FileManager.default.removeItem(at: url)
                context.emit(.deleted(url))
                respondJSON(status: 200, reason: "OK", ["ok": true])
            } catch {
                respondJSON(status: 404, reason: "Not Found", ["error": error.localizedDescription])
            }
        case ("GET", _) where head.path.hasPrefix("/files/"):
            serveFile(String(head.path.dropFirst("/files/".count)))
        default:
            respond(status: 404, reason: "Not Found", body: Data("Not found".utf8), contentType: "text/plain; charset=utf-8")
        }
    }

    private func login(_ head: HTTPRequestHead, body: Data) {
        let text = String(decoding: body, as: UTF8.self)
        var candidate = HTTPRequestHead.decodeForm(text)["pin"]
        if candidate == nil, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            candidate = json["pin"] as? String
        }
        guard context.requirePIN else {
            respondJSON(status: 200, reason: "OK", ["ok": true])
            return
        }
        switch context.login(pin: candidate ?? "", remote: remoteHost) {
        case .success(let token):
            let cookie = "muur_session=\(token); Path=/; HttpOnly; SameSite=Strict"
            if head.wantsHTML && head.headers["x-requested-with"] == nil {
                respond(status: 303, reason: "See Other", headers: ["Location": "/", "Set-Cookie": cookie])
            } else {
                respondJSON(status: 200, reason: "OK", ["ok": true], headers: ["Set-Cookie": cookie])
            }
        case .wrongPIN:
            respondJSON(status: 403, reason: "Forbidden", ["error": "Wrong PIN"])
        case .lockedOut(let seconds):
            respondJSON(status: 429, reason: "Too Many Requests", ["error": "Too many attempts. Try again in \(seconds) s."],
                        headers: ["Retry-After": String(seconds)])
        }
    }

    private func listFiles() -> [[String: Any]] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(at: context.root, includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var files: [[String: Any]] = []
        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            files.append([
                "path": relativePath(of: url),
                "size": values.fileSize ?? 0,
                "modified": (values.contentModificationDate ?? Date()).timeIntervalSince1970,
            ])
            if files.count >= 5000 { break }
        }
        return files.sorted { ($0["path"] as? String ?? "").localizedStandardCompare($1["path"] as? String ?? "") == .orderedAscending }
    }

    private func serveFile(_ relative: String) {
        guard let url = context.resolve(relative),
              let handle = try? FileHandle(forReadingFrom: url),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else {
            respond(status: 404, reason: "Not Found", body: Data("Not found".utf8), contentType: "text/plain; charset=utf-8")
            return
        }
        responded = true
        let name = url.lastPathComponent
        let asciiName = name.unicodeScalars.map { $0.isASCII && $0 != "\"" ? String($0) : "_" }.joined()
        let encodedName = PathUtils.rfc3986Encode(name)
        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: \(PathUtils.mimeType(forExtension: url.pathExtension))\r\n"
        header += "Content-Length: \(size.int64Value)\r\n"
        header += "Content-Disposition: attachment; filename=\"\(asciiName)\"; filename*=UTF-8''\(encodedName)\r\n"
        header += "Connection: close\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                try? handle.close()
                self.connection.cancel()
                return
            }
            self.sendChunk(from: handle)
        })
    }

    private func sendChunk(from handle: FileHandle) {
        let chunk = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
        if chunk.isEmpty {
            try? handle.close()
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
                self?.connection.cancel()
            })
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                try? handle.close()
                self.connection.cancel()
                return
            }
            self.sendChunk(from: handle)
        })
    }

    // MARK: Responses

    private func respondJSON(status: Int, reason: String, _ object: [String: Any], headers: [String: String] = [:]) {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data("{}".utf8)
        respond(status: status, reason: reason, headers: headers, body: data, contentType: "application/json; charset=utf-8")
    }

    private func respond(status: Int, reason: String, headers: [String: String] = [:], body: Data = Data(),
                         contentType: String? = nil) {
        guard !responded else { return }
        responded = true
        var all = headers
        if let contentType { all["Content-Type"] = contentType }
        all["Content-Length"] = String(body.count)
        all["Connection"] = "close"
        all["Cache-Control"] = "no-store"
        all["X-Content-Type-Options"] = "nosniff"
        all["Referrer-Policy"] = "no-referrer"
        var text = "HTTP/1.1 \(status) \(reason)\r\n"
        for (key, value) in all.sorted(by: { $0.key < $1.key }) { text += "\(key): \(value)\r\n" }
        text += "\r\n"
        var data = Data(text.utf8)
        data.append(body)
        connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }
}
