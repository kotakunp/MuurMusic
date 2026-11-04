import Foundation

/// Server presets for WebDAV sources (FEATURES: "WebDAV + presets").
public enum WebDAVPreset: String, Codable, CaseIterable, Sendable, Identifiable {
    case generic, nextcloud, ownCloud, synology, qnap, koofr, yandex, pCloud, box, fourShared, hiDrive, seafile

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .generic: return "WebDAV Server"
        case .nextcloud: return "Nextcloud"
        case .ownCloud: return "ownCloud"
        case .synology: return "Synology NAS"
        case .qnap: return "QNAP NAS"
        case .koofr: return "Koofr"
        case .yandex: return "Yandex Disk"
        case .pCloud: return "pCloud (WebDAV)"
        case .box: return "Box (WebDAV)"
        case .fourShared: return "4shared"
        case .hiDrive: return "STRATO HiDrive"
        case .seafile: return "Seafile"
        }
    }

    /// Fixed host for hosted services (nil = the user enters their own server).
    public var fixedHost: String? {
        switch self {
        case .koofr: return "app.koofr.net"
        case .yandex: return "webdav.yandex.com"
        case .pCloud: return "webdav.pcloud.com"
        case .box: return "dav.box.com"
        case .fourShared: return "webdav.4shared.com"
        case .hiDrive: return "webdav.hidrive.strato.com"
        default: return nil
        }
    }

    public var defaultPort: Int? {
        switch self {
        case .synology: return 5006
        case .qnap: return 443
        default: return nil
        }
    }

    public var defaultUsesTLS: Bool { true }

    /// Server path template; `{user}` is replaced by the URL-encoded user name.
    public var pathTemplate: String {
        switch self {
        case .nextcloud: return "/remote.php/dav/files/{user}/"
        case .ownCloud: return "/remote.php/webdav/"
        case .koofr: return "/dav/Koofr/"
        case .box: return "/dav/"
        case .seafile: return "/seafdav/"
        case .qnap: return "/"
        default: return "/"
        }
    }

    public var help: String {
        switch self {
        case .generic: return "Enter the full WebDAV URL of your server."
        case .nextcloud: return "Use your Nextcloud address and an app password (Settings > Security)."
        case .ownCloud: return "Use your ownCloud address and password."
        case .synology: return "Enable WebDAV in Package Center > WebDAV Server (HTTPS port 5006)."
        case .qnap: return "Enable WebDAV in Control Panel > Applications > Web Server."
        case .koofr: return "Create an application password in Koofr > Preferences > Password."
        case .yandex: return "Use an app password from Yandex ID settings."
        case .pCloud: return "Use your pCloud e-mail and password (EU accounts: ewebdav.pcloud.com)."
        case .box: return "Box WebDAV access may require a Box Business account."
        case .fourShared: return "Use your 4shared e-mail and password."
        case .hiDrive: return "Use your HiDrive user name and password."
        case .seafile: return "Enable SeafDAV on your Seafile server."
        }
    }

    /// Fills host, port, TLS and base path into a configuration.
    public func apply(to config: inout SourceConfig) {
        config.options[SourceConfig.OptionKey.webdavPreset] = rawValue
        if let host = fixedHost { config.host = host }
        if config.port == nil { config.port = defaultPort }
        config.options[SourceConfig.OptionKey.useTLS] = defaultUsesTLS ? "true" : (config.options[SourceConfig.OptionKey.useTLS] ?? "false")
        let user = PathUtils.rfc3986Encode(config.username)
        if config.basePath.isEmpty || config.basePath == "/" {
            config.basePath = pathTemplate.replacingOccurrences(of: "{user}", with: user)
        }
    }
}

/// WebDAV (RFC 4918) file servers.
///
/// `config.host`: host name or full URL ("https://cloud.example.com"); `config.basePath`: server path of the
/// root collection; `useTLS`, `allowInsecureTLS`; credentials `username` + `SourceSecrets.password`.
/// URIs: `webdav(s)://host[:port]/server/path`.
public final class WebDAVSource: MusicSource {
    public let config: SourceConfig
    public var capabilities: SourceCapabilities {
        var caps = SourceCapabilities.fileServer.union(.search)
        if password.isEmpty { caps.insert(.directURL) }
        return caps
    }
    private let http: HTTPClient
    private let baseURL: URL
    private let password: String
    private let scheme: String

    public init(config: SourceConfig, secrets: SourceSecrets) throws {
        self.config = config
        var host = config.host.trimmingCharacters(in: .whitespaces)
        if let preset = config.option(SourceConfig.OptionKey.webdavPreset).flatMap(WebDAVPreset.init(rawValue:)), let fixed = preset.fixedHost, host.isEmpty {
            host = fixed
        }
        guard !host.isEmpty else { throw MuurError.notConfigured("WebDAV server address") }
        var components: URLComponents
        if host.contains("://"), let parsed = URLComponents(string: host) {
            components = parsed
        } else {
            components = URLComponents()
            components.scheme = config.useTLS ? "https" : "http"
            components.host = host
        }
        if let port = config.port { components.port = port }
        var basePath = components.path.isEmpty || components.path == "/" ? config.basePath : components.path
        if basePath.isEmpty { basePath = "/" }
        if !basePath.hasPrefix("/") { basePath = "/" + basePath }
        if !basePath.hasSuffix("/") { basePath += "/" }
        components.percentEncodedPath = PathUtils.percentEncodePath(basePath.removingPercentEncoding ?? basePath)
        components.query = nil
        guard let url = components.url else { throw MuurError.invalidData("Invalid WebDAV URL") }
        baseURL = url
        scheme = url.scheme == "https" ? "webdavs" : "webdav"
        password = secrets.password ?? ""
        let credential = config.username.isEmpty ? nil : URLCredential(user: config.username, password: password, persistence: .forSession)
        http = HTTPClient(allowInsecureTLS: config.allowInsecureTLS, credential: credential)
    }

    /// The normalized base URL (useful for display).
    public var serverURL: URL { baseURL }

    private var authHeaders: [String: String] {
        guard !config.username.isEmpty else { return [:] }
        let token = Data("\(config.username):\(password)".utf8).base64EncodedString()
        return ["Authorization": "Basic \(token)"]
    }

    private var rootPath: String {
        URLComponents(url: baseURL, resolvingAgainstBaseURL: false)?.path ?? "/"
    }

    func url(forPath path: String) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = PathUtils.percentEncodePath(path)
        return components.url!
    }

    private func uri(for path: String) -> String {
        SourceURI(scheme: scheme, authority: baseURL.host ?? config.host, path: path, port: baseURL.port).description
    }

    private func path(of uri: String) throws -> String {
        guard let parsed = SourceURI.parse(uri), parsed.scheme.hasPrefix("webdav") else { throw MuurError.invalidData("Not a WebDAV URI") }
        return parsed.path
    }

    private static let propfindBody = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:getcontenttype/></d:prop></d:propfind>
    """

    private func propfind(path: String, depth: String) async throws -> [SourceItem] {
        var headers = authHeaders
        headers["Depth"] = depth
        headers["Content-Type"] = "application/xml; charset=utf-8"
        let request = URLRequest(url: url(forPath: path), method: "PROPFIND", headers: headers, body: Data(WebDAVSource.propfindBody.utf8))
        let (data, _) = try await http.data(for: request)
        let root = try XMLTree.parse(data)
        var items: [SourceItem] = []
        let normalizedSelf = WebDAVSource.normalize(path)
        for response in root.descendants("response") {
            guard let hrefText = response.childText("href") else { continue }
            let hrefPath = WebDAVSource.decodeHref(hrefText)
            if WebDAVSource.normalize(hrefPath) == normalizedSelf && depth == "1" { continue }
            var prop: XNode?
            for propstat in response.children("propstat") {
                let status = propstat.childText("status") ?? "200"
                if status.contains("200") { prop = propstat.child("prop"); break }
            }
            guard let prop else { continue }
            let isCollection = prop.child("resourcetype")?.child("collection") != nil
            var name = prop.childText("displayname") ?? ""
            if name.isEmpty || name.contains("/") { name = PathUtils.lastComponent(hrefPath) }
            guard !name.hasPrefix(".") else { continue }
            let cleanPath = isCollection ? (hrefPath.hasSuffix("/") ? hrefPath : hrefPath + "/") : hrefPath
            let kind: SourceItem.Kind = isCollection ? .folder : SourceItem.kind(forFileName: PathUtils.lastComponent(hrefPath))
            items.append(SourceItem(uri: uri(for: cleanPath), name: name, kind: kind, path: cleanPath,
                                    size: prop.childText("getcontentlength").flatMap { Int64($0) },
                                    modified: prop.childText("getlastmodified").flatMap(DateParsing.rfc1123Date),
                                    mimeType: prop.childText("getcontenttype")))
        }
        return items
    }

    static func decodeHref(_ href: String) -> String {
        var path = href
        if let url = URL(string: href), url.scheme != nil {
            path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        }
        return path.removingPercentEncoding ?? path
    }

    static func normalize(_ path: String) -> String {
        var value = path.removingPercentEncoding ?? path
        while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        return value
    }

    public func connect() async throws {
        _ = try await propfind(path: rootPath, depth: "0")
    }

    public func list(_ container: SourceItem?) async throws -> [SourceItem] {
        let items = try await propfind(path: container?.path ?? rootPath, depth: "1")
        return items.sorted {
            ($0.kind == .folder ? 0 : 1, $0.name.localizedLowercase) < ($1.kind == .folder ? 0 : 1, $1.name.localizedLowercase)
        }
    }

    /// Breadth-first name search (WebDAV SEARCH is rarely implemented); limited to 2000 folders.
    public func search(_ text: String) async throws -> [SourceItem] {
        let needle = text.lowercased()
        guard !needle.isEmpty else { return [] }
        var queue = [rootPath]
        var visited = 0
        var results: [SourceItem] = []
        while !queue.isEmpty && visited < 2000 && results.count < 300 {
            try Task.checkCancellation()
            let path = queue.removeFirst()
            visited += 1
            guard let items = try? await propfind(path: path, depth: "1") else { continue }
            for item in items {
                if item.kind == .folder { queue.append(item.path) }
                if item.name.lowercased().contains(needle) { results.append(item) }
            }
        }
        return results
    }

    public func streamURL(for uri: String) async throws -> RemoteResource? {
        let itemPath = try self.path(of: uri)
        var url = self.url(forPath: itemPath)
        if !config.username.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            // Renderers that cannot send headers accept userinfo credentials.
            components.user = config.username
            components.password = password
            url = components.url ?? url
            return RemoteResource(url: url, headers: authHeaders)
        }
        return RemoteResource(url: url)
    }

    public func download(uri: String, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let request = URLRequest(url: url(forPath: try path(of: uri)), method: "GET", headers: authHeaders)
        try await http.download(request, to: destination, progress: progress)
    }

    public func upload(from localURL: URL, to container: SourceItem?, fileName: String) async throws {
        let folder = container?.path ?? rootPath
        let target = (folder.hasSuffix("/") ? folder : folder + "/") + fileName
        var headers = authHeaders
        headers["Content-Type"] = PathUtils.mimeType(forExtension: PathUtils.fileExtension(fileName))
        let request = URLRequest(url: url(forPath: target), method: "PUT", headers: headers, body: try Data(contentsOf: localURL, options: .mappedIfSafe))
        _ = try await http.data(for: request)
    }

    public func delete(_ item: SourceItem) async throws {
        _ = try await http.data(for: URLRequest(url: url(forPath: item.path), method: "DELETE", headers: authHeaders))
    }

    public func rename(_ item: SourceItem, to newName: String) async throws {
        let trimmed = item.path.hasSuffix("/") ? String(item.path.dropLast()) : item.path
        var target = SourcePaths.child(PathUtils.parent(trimmed), newName)
        if item.kind == .folder { target += "/" }
        var headers = authHeaders
        headers["Destination"] = url(forPath: target).absoluteString
        headers["Overwrite"] = "F"
        _ = try await http.data(for: URLRequest(url: url(forPath: item.path), method: "MOVE", headers: headers))
    }

    public func createFolder(named name: String, in container: SourceItem?) async throws {
        let folder = container?.path ?? rootPath
        let target = (folder.hasSuffix("/") ? folder : folder + "/") + name + "/"
        _ = try await http.data(for: URLRequest(url: url(forPath: target), method: "MKCOL", headers: authHeaders))
    }
}
