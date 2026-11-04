import Foundation
import Network

/// Byte stream used for FTP control and data connections.
protocol FTPByteStream: AnyObject, Sendable {
    func open() async throws
    func send(_ data: Data) async throws
    /// Next chunk of bytes; nil at end of stream.
    func receive(maximum: Int) async throws -> Data?
    /// Upgrades the connection to TLS (explicit FTPS).
    func startTLS() async throws
    func close()
}

/// TCP / TLS stream on `NWConnection` (plain FTP and implicit FTPS).
final class NWByteStream: FTPByteStream, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "app.muur.ftp.nw")

    init(host: String, port: UInt16, tls: Bool, allowInsecureTLS: Bool) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw MuurError.invalidData("Invalid port \(port)") }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 20
        let parameters: NWParameters
        if tls {
            let tlsOptions = NWProtocolTLS.Options()
            if allowInsecureTLS {
                sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { _, _, complete in
                    complete(true)
                }, queue)
            }
            parameters = NWParameters(tls: tlsOptions, tcp: tcp)
        } else {
            parameters = NWParameters(tls: nil, tcp: tcp)
        }
        connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
    }

    func open() async throws {
        let resumed = LockedValue(false)
        let connection = self.connection
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                func finish(_ result: Result<Void, Error>) {
                    let already = resumed.mutate { value -> Bool in
                        let was = value
                        value = true
                        return was
                    }
                    if !already { continuation.resume(with: result) }
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        finish(.success(()))
                    case .failed(let error):
                        finish(.failure(MuurError.network(error.localizedDescription)))
                    case .waiting(let error):
                        finish(.failure(MuurError.network(error.localizedDescription)))
                        connection.cancel()
                    case .cancelled:
                        finish(.failure(MuurError.cancelled))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: MuurError.network(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func receive(maximum: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: MuurError.network(error.localizedDescription))
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    func startTLS() async throws {
        throw MuurError.unsupported("Upgrading a Network.framework connection to TLS")
    }

    func close() {
        connection.cancel()
    }
}

/// `URLSessionStreamTask` based stream: supports in-place TLS upgrade for explicit FTPS (AUTH TLS),
/// which `NWConnection` cannot do.
final class StreamTaskByteStream: NSObject, FTPByteStream, URLSessionDelegate, @unchecked Sendable {
    private var session: URLSession!
    private var active: URLSessionStreamTask!
    private let allowInsecureTLS: Bool

    init(host: String, port: UInt16, allowInsecureTLS: Bool) {
        self.allowInsecureTLS = allowInsecureTLS
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        active = session.streamTask(withHostName: host, port: Int(port))
    }

    func open() async throws {
        active.resume()
    }

    func send(_ data: Data) async throws {
        let task = active
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.write(data, timeout: 60) { error in
                if let error {
                    continuation.resume(throwing: MuurError.network(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func receive(maximum: Int) async throws -> Data? {
        let task = active
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            task.readData(ofMinLength: 1, maxLength: maximum, timeout: 120) { data, atEOF, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: MuurError.network(error.localizedDescription))
                } else if atEOF {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    func startTLS() async throws {
        active.startSecureConnection()
    }

    func close() {
        active.closeWrite()
        active.cancel()
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           allowInsecureTLS, let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

/// One entry of an FTP directory listing.
public struct FTPListEntry: Hashable, Sendable {
    public var name: String
    public var isDirectory: Bool
    public var isLink: Bool
    public var size: Int64?
    public var modified: Date?

    public init(name: String, isDirectory: Bool, isLink: Bool = false, size: Int64? = nil, modified: Date? = nil) {
        self.name = name
        self.isDirectory = isDirectory
        self.isLink = isLink
        self.size = size
        self.modified = modified
    }
}

/// Parses MLSD facts, Unix `ls -l` and Windows/IIS directory listings.
public enum FTPListParser {
    public static func parseMLSD(_ line: String) -> FTPListEntry? {
        guard let space = line.firstIndex(of: " ") else { return nil }
        let facts = line[..<space].split(separator: ";")
        let name = String(line[line.index(after: space)...])
        var type = "file"
        var size: Int64?
        var modified: Date?
        for fact in facts {
            let pair = fact.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            switch pair[0].lowercased() {
            case "type": type = pair[1].lowercased()
            case "size": size = Int64(pair[1])
            case "modify": modified = mlsdDate(pair[1])
            default: break
            }
        }
        if type == "cdir" || type == "pdir" || name == "." || name == ".." { return nil }
        let isDirectory = type == "dir"
        return FTPListEntry(name: name, isDirectory: isDirectory, isLink: type.contains("link"),
                            size: isDirectory ? nil : size, modified: modified)
    }

    static func mlsdDate(_ value: String) -> Date? {
        let digits = value.prefix(14)
        guard digits.count == 14 else { return nil }
        var components = DateComponents()
        components.timeZone = TimeZone(identifier: "UTC")
        let s = Array(digits)
        func number(_ range: Range<Int>) -> Int? { Int(String(s[range])) }
        components.year = number(0..<4)
        components.month = number(4..<6)
        components.day = number(6..<8)
        components.hour = number(8..<10)
        components.minute = number(10..<12)
        components.second = number(12..<14)
        return Calendar(identifier: .gregorian).date(from: components)
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    public static func parseList(_ line: String, now: Date = Date()) -> FTPListEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.lowercased().hasPrefix("total ") else { return nil }
        if let first = trimmed.first, "dl-bcps".contains(first) {
            return parseUnix(trimmed, now: now)
        }
        if let first = trimmed.first, first.isNumber {
            return parseDOS(trimmed)
        }
        return nil
    }

    /// `drwxr-xr-x 2 user group 4096 Mar 21 12:01 name` / `... Mar 21  2019 name`.
    static func parseUnix(_ line: String, now: Date) -> FTPListEntry? {
        var fields: [Substring] = []
        var index = line.startIndex
        // The name is everything after the 8th whitespace-separated field.
        while fields.count < 8 && index < line.endIndex {
            while index < line.endIndex && line[index] == " " { index = line.index(after: index) }
            let start = index
            while index < line.endIndex && line[index] != " " { index = line.index(after: index) }
            if start < index { fields.append(line[start..<index]) }
        }
        guard fields.count == 8, index < line.endIndex else { return nil }
        var name = String(line[line.index(after: index)...])
        let type = fields[0].first
        // Some servers omit the group column: detect by the month position.
        var sizeField = fields[4]
        var monthField = fields[5]
        var dayField = fields[6]
        var timeField = fields[7]
        if !months.contains(monthField.lowercased()), months.contains(fields[4].lowercased()) {
            sizeField = fields[3]
            monthField = fields[4]
            dayField = fields[5]
            timeField = fields[6]
            name = String(fields[7]) + " " + name
        }
        var isLink = false
        if type == "l" {
            isLink = true
            if let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
        }
        guard name != ".", name != ".." else { return nil }
        let isDirectory = type == "d"
        var modified: Date?
        if let month = months.firstIndex(of: monthField.lowercased()), let day = Int(dayField) {
            var components = DateComponents()
            components.month = month + 1
            components.day = day
            let calendar = Calendar(identifier: .gregorian)
            if timeField.contains(":") {
                let hm = timeField.split(separator: ":")
                components.hour = Int(hm[0])
                components.minute = hm.count > 1 ? Int(hm[1]) : 0
                let year = calendar.component(.year, from: now)
                components.year = year
                if let date = calendar.date(from: components), date > now.addingTimeInterval(86_400) {
                    components.year = year - 1
                }
            } else {
                components.year = Int(timeField)
            }
            modified = calendar.date(from: components)
        }
        return FTPListEntry(name: name, isDirectory: isDirectory, isLink: isLink, size: isDirectory ? nil : Int64(sizeField),
                            modified: modified)
    }

    /// `03-21-19  12:01PM       <DIR>          name` / `... 12345 name`.
    static func parseDOS(_ line: String) -> FTPListEntry? {
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count == 4 else { return nil }
        let name = String(parts[3]).trimmingCharacters(in: .whitespaces)
        let isDirectory = parts[2].uppercased() == "<DIR>"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = parts[0].count > 8 ? "MM-dd-yyyy hh:mma" : "MM-dd-yy hh:mma"
        let modified = formatter.date(from: "\(parts[0]) \(parts[1])")
        return FTPListEntry(name: name, isDirectory: isDirectory, size: isDirectory ? nil : Int64(parts[2]), modified: modified)
    }
}

/// FTP TLS modes.
public enum FTPTLSMode: String, Codable, Sendable, CaseIterable {
    case none, explicit, implicit
}

/// A single FTP control connection. All operations are serialized (FTP is a stateful protocol).
actor FTPConnection {
    struct Reply {
        var code: Int
        var text: String
    }

    private let host: String
    private let port: UInt16
    private let user: String
    private let password: String
    private let tlsMode: FTPTLSMode
    private let allowInsecureTLS: Bool
    private var control: FTPByteStream?
    private var buffer = Data()
    private var supportsMLSD = false
    private var supportsEPSV = true
    private(set) var workingDirectory = "/"

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(host: String, port: UInt16, user: String, password: String, tlsMode: FTPTLSMode, allowInsecureTLS: Bool) {
        self.host = host
        self.port = port
        self.user = user.isEmpty ? "anonymous" : user
        self.password = user.isEmpty ? "muurmusic@" : password
        self.tlsMode = tlsMode
        self.allowInsecureTLS = allowInsecureTLS
    }

    // MARK: Serialization

    private func acquire() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    func exclusive<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        do {
            try await ensureConnected()
            return try await body()
        } catch let error as MuurError {
            if case .network = error { dropConnection() }
            throw error
        }
    }

    // MARK: Control channel

    private func makeStream(host: String, port: UInt16) throws -> FTPByteStream {
        switch tlsMode {
        case .none: return try NWByteStream(host: host, port: port, tls: false, allowInsecureTLS: allowInsecureTLS)
        case .implicit: return try NWByteStream(host: host, port: port, tls: true, allowInsecureTLS: allowInsecureTLS)
        case .explicit: return StreamTaskByteStream(host: host, port: port, allowInsecureTLS: allowInsecureTLS)
        }
    }

    private func dropConnection() {
        control?.close()
        control = nil
        buffer.removeAll()
    }

    func disconnect() async {
        await acquire()
        defer { release() }
        if control != nil {
            _ = try? await command("QUIT")
        }
        dropConnection()
    }

    private func ensureConnected() async throws {
        if control != nil { return }
        do {
            try await establish()
        } catch {
            dropConnection()
            throw error
        }
    }

    private func establish() async throws {
        let stream = try makeStream(host: host, port: port)
        try await stream.open()
        control = stream
        buffer.removeAll()
        let greeting = try await readReply()
        guard greeting.code == 220 else { throw MuurError.protocolError("Unexpected greeting: \(greeting.text)") }
        if tlsMode == .explicit {
            let auth = try await command("AUTH TLS")
            guard auth.code == 234 else { throw MuurError.protocolError("Server does not support AUTH TLS: \(auth.text)") }
            try await stream.startTLS()
        }
        var reply = try await command("USER \(user)")
        if reply.code == 331 || reply.code == 332 {
            reply = try await command("PASS \(password)")
        }
        guard reply.code == 230 || reply.code == 202 else {
            dropConnection()
            throw MuurError.authenticationFailed(reply.text)
        }
        if tlsMode != .none {
            _ = try await command("PBSZ 0")
            let prot = try await command("PROT P")
            guard prot.code == 200 else { throw MuurError.protocolError("PROT P rejected: \(prot.text)") }
        }
        let features = try await command("FEAT")
        if features.code == 211 {
            let upper = features.text.uppercased()
            supportsMLSD = upper.contains("MLSD") || upper.contains("MLST")
            if upper.contains("UTF8") { _ = try await command("OPTS UTF8 ON") }
        }
        _ = try await command("TYPE I")
        let pwd = try await command("PWD")
        if pwd.code == 257, let open = pwd.text.firstIndex(of: "\""), let close = pwd.text[pwd.text.index(after: open)...].firstIndex(of: "\"") {
            workingDirectory = String(pwd.text[pwd.text.index(after: open)..<close])
        }
    }

    private func readLine() async throws -> String {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                var lineData = buffer[buffer.startIndex..<newline]
                if lineData.last == 0x0D { lineData = lineData.dropLast() }
                buffer.removeSubrange(buffer.startIndex...newline)
                return String(data: lineData, encoding: .utf8) ?? String(data: lineData, encoding: .isoLatin1) ?? ""
            }
            guard let control else { throw MuurError.network("FTP connection closed") }
            guard let chunk = try await control.receive(maximum: 8192) else {
                dropConnection()
                throw MuurError.network("FTP server closed the connection")
            }
            buffer.append(chunk)
        }
    }

    private func readReply() async throws -> Reply {
        let first = try await readLine()
        guard first.count >= 3, let code = Int(first.prefix(3)) else { throw MuurError.protocolError("Bad reply: \(first)") }
        var text = String(first.dropFirst(4))
        if first.count > 3 && first[first.index(first.startIndex, offsetBy: 3)] == "-" {
            let terminator = String(first.prefix(3)) + " "
            while true {
                let line = try await readLine()
                text += "\n" + line
                if line.hasPrefix(terminator) { break }
            }
        }
        return Reply(code: code, text: text)
    }

    @discardableResult
    private func command(_ line: String) async throws -> Reply {
        guard let control else { throw MuurError.network("FTP connection closed") }
        try await control.send(Data((line + "\r\n").utf8))
        return try await readReply()
    }

    private func require(_ line: String, _ codes: Set<Int>) async throws -> Reply {
        let reply = try await command(line)
        guard codes.contains(reply.code) else {
            if reply.code == 550 { throw MuurError.notFound(reply.text) }
            if reply.code == 530 { throw MuurError.authenticationFailed(reply.text) }
            throw MuurError.protocolError("\(line.split(separator: " ").first ?? ""): \(reply.code) \(reply.text)")
        }
        return reply
    }

    // MARK: Data channel

    private func openDataStream() async throws -> FTPByteStream {
        var dataPort: UInt16?
        if supportsEPSV {
            let reply = try await command("EPSV")
            if reply.code == 229, let open = reply.text.firstIndex(of: "("), let close = reply.text.lastIndex(of: ")") {
                let inner = reply.text[reply.text.index(after: open)..<close]
                let digits = inner.filter(\.isNumber)
                dataPort = UInt16(digits)
            } else {
                supportsEPSV = false
            }
        }
        if dataPort == nil {
            let reply = try await require("PASV", [227])
            guard let open = reply.text.firstIndex(of: "("), let close = reply.text.lastIndex(of: ")") else {
                throw MuurError.protocolError("Bad PASV reply")
            }
            let numbers = reply.text[reply.text.index(after: open)..<close].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard numbers.count == 6 else { throw MuurError.protocolError("Bad PASV reply") }
            // The advertised address is ignored: servers behind NAT often report private addresses.
            dataPort = UInt16(numbers[4] * 256 + numbers[5])
        }
        guard let port = dataPort else { throw MuurError.protocolError("No passive port") }
        let stream = try makeStream(host: host, port: port)
        try await stream.open()
        if tlsMode == .explicit { try await stream.startTLS() }
        return stream
    }

    /// Runs a transfer command, handing the data stream to `body`, then reads the completion reply.
    private func transfer(_ line: String, _ body: (FTPByteStream) async throws -> Void) async throws {
        let stream = try await openDataStream()
        defer { stream.close() }
        let start = try await command(line)
        guard start.code == 125 || start.code == 150 else {
            if start.code == 550 { throw MuurError.notFound(start.text) }
            throw MuurError.protocolError("\(line.split(separator: " ").first ?? ""): \(start.code) \(start.text)")
        }
        do {
            try await body(stream)
        } catch {
            stream.close()
            _ = try? await command("ABOR")
            dropConnection()
            throw error
        }
        stream.close()
        let done = try await readReply()
        guard done.code == 226 || done.code == 250 else { throw MuurError.protocolError("Transfer failed: \(done.code) \(done.text)") }
    }

    // MARK: Operations (call inside `exclusive`)

    func listUnlocked(_ path: String) async throws -> [FTPListEntry] {
        var data = Data()
        let useMLSD = supportsMLSD
        try await transfer(useMLSD ? "MLSD \(path)" : "LIST -a \(path)") { stream in
            while let chunk = try await stream.receive(maximum: 65_536) {
                data.append(chunk)
            }
        }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        return text.components(separatedBy: "\n").compactMap { raw in
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            return useMLSD ? FTPListParser.parseMLSD(line) : FTPListParser.parseList(line)
        }
    }

    func retrieveUnlocked(_ path: String, to destination: URL, expected: Int64,
                          progress: @Sendable (Int64, Int64) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        guard fm.createFile(atPath: destination.path, contents: nil) else { throw MuurError.io("Cannot create \(destination.lastPathComponent)") }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var received: Int64 = 0
        do {
            try await transfer("RETR \(path)") { stream in
                while let chunk = try await stream.receive(maximum: 256 * 1024) {
                    try Task.checkCancellation()
                    try handle.write(contentsOf: chunk)
                    received += Int64(chunk.count)
                    progress(received, expected)
                }
            }
        } catch {
            try? handle.close()
            try? fm.removeItem(at: destination)
            if error is CancellationError { throw MuurError.cancelled }
            throw error
        }
    }

    func sizeUnlocked(_ path: String) async throws -> Int64? {
        let reply = try await command("SIZE \(path)")
        return reply.code == 213 ? Int64(reply.text.trimmingCharacters(in: .whitespaces)) : nil
    }

    func storeUnlocked(from localURL: URL, to path: String) async throws {
        let input = try FileHandle(forReadingFrom: localURL)
        defer { try? input.close() }
        try await transfer("STOR \(path)") { stream in
            while let chunk = try input.read(upToCount: 256 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                try await stream.send(chunk)
            }
        }
    }

    func simpleUnlocked(_ line: String, codes: Set<Int>) async throws {
        _ = try await require(line, codes)
    }

    func renameUnlocked(from: String, to: String) async throws {
        _ = try await require("RNFR \(from)", [350])
        _ = try await require("RNTO \(to)", [250])
    }
}

/// FTP and FTPS servers through a Network.framework client (explicit FTPS uses `URLSessionStreamTask`
/// for the in-place TLS upgrade).
///
/// `config.host`, `config.port` (21 / 990 implicit), `username` (empty = anonymous) + `password`;
/// options `useTLS` = "true" and `ftpTLSMode` = "explicit" (default) | "implicit"; `allowInsecureTLS`.
/// URIs: `ftp(s)://host[:port]/path`.
public final class FTPSource: MusicSource {
    public let config: SourceConfig
    public var capabilities: SourceCapabilities { SourceCapabilities.fileServer }
    private let connection: FTPConnection
    private let scheme: String

    public init(config: SourceConfig, secrets: SourceSecrets) throws {
        guard !config.host.isEmpty else { throw MuurError.notConfigured("FTP server address") }
        self.config = config
        var mode: FTPTLSMode = .none
        if config.useTLS {
            mode = FTPTLSMode(rawValue: config.option(SourceConfig.OptionKey.ftpTLSMode) ?? "explicit") ?? .explicit
            if mode == .none { mode = .explicit }
        }
        scheme = mode == .none ? "ftp" : "ftps"
        let port = UInt16(config.port ?? (mode == .implicit ? 990 : 21))
        connection = FTPConnection(host: config.host.trimmingCharacters(in: .whitespaces), port: port, user: config.username,
                                   password: secrets.password ?? "", tlsMode: mode, allowInsecureTLS: config.allowInsecureTLS)
    }

    private func rootPath() async throws -> String {
        let base = config.basePath.trimmingCharacters(in: .whitespaces)
        if base.hasPrefix("/") { return SourcePaths.root(base) }
        let home = try await connection.exclusive { await self.connection.workingDirectory }
        return base.isEmpty ? home : SourcePaths.child(home, base)
    }

    private func uri(for path: String) -> String {
        let defaultPort = scheme == "ftps" && config.option(SourceConfig.OptionKey.ftpTLSMode) == "implicit" ? 990 : 21
        return SourceURI(scheme: scheme, authority: config.host, path: path, port: config.port == defaultPort ? nil : config.port).description
    }

    public func connect() async throws {
        let root = try await rootPath()
        let connection = self.connection
        _ = try await connection.exclusive { try await connection.listUnlocked(root) }
    }

    public func disconnect() async {
        await connection.disconnect()
    }

    public func list(_ container: SourceItem?) async throws -> [SourceItem] {
        let path: String
        if let container { path = container.path } else { path = try await rootPath() }
        let connection = self.connection
        let entries = try await connection.exclusive { try await connection.listUnlocked(path) }
        return entries.filter { !$0.name.hasPrefix(".") }.map { entry in
            let childPath = SourcePaths.child(path, entry.name)
            return SourceItem(uri: uri(for: childPath), name: entry.name,
                              kind: entry.isDirectory ? .folder : SourceItem.kind(forFileName: entry.name),
                              path: childPath, size: entry.size, modified: entry.modified)
        }
        .sorted { ($0.kind == .folder ? 0 : 1, $0.name.localizedLowercase) < ($1.kind == .folder ? 0 : 1, $1.name.localizedLowercase) }
    }

    public func download(uri: String, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        guard let parsed = SourceURI.parse(uri), parsed.scheme.hasPrefix("ftp") else { throw MuurError.invalidData("Not an FTP URI") }
        let connection = self.connection
        try await connection.exclusive {
            let size: Int64 = (try? await connection.sizeUnlocked(parsed.path)).flatMap { $0 } ?? 0
            try await connection.retrieveUnlocked(parsed.path, to: destination, expected: size, progress: progress)
        }
    }

    private func containerPath(_ container: SourceItem?) async throws -> String {
        if let container { return container.path }
        return try await rootPath()
    }

    public func upload(from localURL: URL, to container: SourceItem?, fileName: String) async throws {
        let target = SourcePaths.child(try await containerPath(container), fileName)
        let connection = self.connection
        try await connection.exclusive { try await connection.storeUnlocked(from: localURL, to: target) }
    }

    public func delete(_ item: SourceItem) async throws {
        let connection = self.connection
        let line = item.kind == .folder ? "RMD \(item.path)" : "DELE \(item.path)"
        try await connection.exclusive { try await connection.simpleUnlocked(line, codes: [250, 200]) }
    }

    public func rename(_ item: SourceItem, to newName: String) async throws {
        let connection = self.connection
        let target = SourcePaths.child(PathUtils.parent(item.path), newName)
        try await connection.exclusive { try await connection.renameUnlocked(from: item.path, to: target) }
    }

    public func createFolder(named name: String, in container: SourceItem?) async throws {
        let target = SourcePaths.child(try await containerPath(container), name)
        let connection = self.connection
        try await connection.exclusive { try await connection.simpleUnlocked("MKD \(target)", codes: [257, 250]) }
    }
}
