import Foundation

// MARK: - Helpers

extension Array where Element == SourceItem {
    /// Folders first, then by name.
    func sortedForBrowsing() -> [SourceItem] {
        sorted { ($0.kind == .folder ? 0 : 1, $0.name.localizedLowercase) < ($1.kind == .folder ? 0 : 1, $1.name.localizedLowercase) }
    }
}

enum JSONRead {
    static func string(_ object: [String: Any], _ key: String) -> String? {
        if let value = object[key] as? String { return value }
        if let value = object[key] as? NSNumber { return value.stringValue }
        return nil
    }

    static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        int64(value).map { Int(clamping: $0) }
    }

    static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    static func bool(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String { return text == "true" || text == "1" }
        return false
    }

    static func objects(_ value: Any?) -> [[String: Any]] {
        value as? [[String: Any]] ?? []
    }
}

/// multipart/form-data body builder.
struct MultipartForm {
    let boundary = "MuurBoundary" + Hashing.randomToken(length: 20)
    private(set) var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(_ name: String, value: String, contentType: String? = nil) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n".utf8))
        if let contentType { body.append(Data("Content-Type: \(contentType)\r\n".utf8)) }
        body.append(Data("\r\n\(value)\r\n".utf8))
    }

    mutating func addFile(_ name: String, fileName: String, mimeType: String, data: Data) {
        let safeName = fileName.replacingOccurrences(of: "\"", with: "'")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(safeName)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    func finalized() -> Data {
        var result = body
        result.append(Data("--\(boundary)--\r\n".utf8))
        return result
    }
}

private func cloudSession(_ config: SourceConfig, _ secrets: SourceSecrets, credentials: CredentialStore) throws -> OAuthSession {
    guard let provider = OAuthProvider(kind: config.kind) else { throw MuurError.unsupported(config.kind.displayName) }
    guard let tokens = secrets.oauth else { throw MuurError.authenticationFailed("Sign in to \(provider.displayName) first") }
    return OAuthSession(provider: provider, sourceID: config.id, tokens: tokens, credentials: credentials)
}

private func idURI(_ config: SourceConfig, _ id: String) -> String {
    SourceURI(scheme: config.kind.uriScheme, authority: config.id.uuidString, path: id).description
}

private func itemID(_ uri: String, scheme: String) throws -> String {
    guard let parsed = SourceURI.parse(uri), parsed.scheme == scheme else { throw MuurError.invalidData("Not a \(scheme) URI") }
    return parsed.path
}

// MARK: - Dropbox

/// Dropbox (API v2). `config.basePath`: optional start folder ("/Music"). URIs: `dropbox://<sourceId>/<path>`.
public final class DropboxSource: MusicSource {
    public let config: SourceConfig
    public var capabilities: SourceCapabilities { SourceCapabilities.fileServer.union([.search, .directURL]) }
    private let api: CloudHTTP
    private static let rpc = "https://api.dropboxapi.com/2/"
    private static let content = "https://content.dropboxapi.com/2/"

    public init(config: SourceConfig, secrets: SourceSecrets, credentials: CredentialStore) throws {
        self.config = config
        api = CloudHTTP(session: try cloudSession(config, secrets, credentials: credentials))
    }

    private var rootPath: String {
        let base = SourcePaths.root(config.basePath)
        return base == "/" ? "" : base
    }

    private func call(_ endpoint: String, _ body: [String: Any]) async throws -> [String: Any] {
        try await api.json(URL(string: DropboxSource.rpc + endpoint)!, method: "POST", body: body)
    }

    /// Dropbox-API-Arg must be ASCII: non-ASCII characters are escaped as \uXXXX.
    static func headerJSON(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        let text = String(decoding: data, as: UTF8.self)
        var result = ""
        for unit in text.utf16 {
            if unit < 0x80 {
                result.append(Character(Unicode.Scalar(UInt8(unit))))
            } else {
                result += String(format: "\\u%04x", unit)
            }
        }
        return result
    }

    private func item(_ entry: [String: Any]) -> SourceItem? {
        guard let name = JSONRead.string(entry, "name"), let path = JSONRead.string(entry, "path_display") else { return nil }
        let isFolder = JSONRead.string(entry, ".tag") == "folder"
        return SourceItem(uri: idURI(config, path), name: name, kind: isFolder ? .folder : SourceItem.kind(forFileName: name), path: path,
                          size: isFolder ? nil : JSONRead.int64(entry["size"]),
                          modified: JSONRead.string(entry, "server_modified").flatMap(DateParsing.iso8601Date))
    }

    public func connect() async throws {
        _ = try await call("files/list_folder", ["path": rootPath, "limit": 1])
    }

    public func list(_ container: SourceItem?) async throws -> [SourceItem] {
        var response = try await call("files/list_folder", ["path": container?.path ?? rootPath, "limit": 2000])
        var items: [SourceItem] = []
        while true {
            items += JSONRead.objects(response["entries"]).compactMap(item)
            guard JSONRead.bool(response["has_more"]), let cursor = response["cursor"] as? String else { break }
            response = try await call("files/list_folder/continue", ["cursor": cursor])
        }
        return items.filter { !$0.name.hasPrefix(".") }.sortedForBrowsing()
    }

    public func search(_ text: String) async throws -> [SourceItem] {
        var options: [String: Any] = ["max_results": 200, "file_status": "active"]
        if !rootPath.isEmpty { options["path"] = rootPath }
        let response = try await call("files/search_v2", ["query": text, "options": options])
        return JSONRead.objects(response["matches"]).compactMap { match in
            ((match["metadata"] as? [String: Any])?["metadata"] as? [String: Any]).flatMap(item)
        }
    }

    private func path(of uri: String) throws -> String {
        "/" + (try itemID(uri, scheme: "dropbox"))
    }

    public func streamURL(for uri: String) async throws -> RemoteResource? {
        let response = try await call("files/get_temporary_link", ["path": try path(of: uri)])
        guard let link = response["link"] as? String, let url = URL(string: link) else { throw MuurError.notFound(uri) }
        return RemoteResource(url: url)
    }

    public func download(uri: String, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        guard let resource = try await streamURL(for: uri) else { throw MuurError.notFound(uri) }
        try await api.http.download(URLRequest(url: resource.url), to: destination, progress: progress)
    }

    public func upload(from localURL: URL, to container: SourceItem?, fileName: String) async throws {
        let target = (container?.path ?? rootPath) + "/" + fileName
        let size = ((try? FileManager.default.attributesOfItem(atPath: localURL.path))?[.size] as? NSNumber)?.int64Value ?? 0
        let commit: [String: Any] = ["path": target, "mode": "add", "autorename": true]
        let chunkSize = 8 * 1024 * 1024
        if size <= 150 * 1024 * 1024 {
            let data = try Data(contentsOf: localURL, options: .mappedIfSafe)
            let request = URLRequest(url: URL(string: DropboxSource.content + "files/upload")!, method: "POST", headers: [
                "Dropbox-API-Arg": try DropboxSource.headerJSON(commit), "Content-Type": "application/octet-stream",
            ], body: data)
            _ = try await api.data(request)
            return
        }
        let handle = try FileHandle(forReadingFrom: localURL)
        defer { try? handle.close() }
        let first = try handle.read(upToCount: chunkSize) ?? Data()
        let start = URLRequest(url: URL(string: DropboxSource.content + "files/upload_session/start")!, method: "POST", headers: [
            "Dropbox-API-Arg": "{\"close\":false}", "Content-Type": "application/octet-stream",
        ], body: first)
        let (startData, _) = try await api.data(start)
        guard let sessionID = (try JSONSerialization.jsonObject(with: startData) as? [String: Any])?["session_id"] as? String else {
            throw MuurError.invalidData("Dropbox upload session")
        }
        var offset = Int64(first.count)
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            let cursor: [String: Any] = ["session_id": sessionID, "offset": offset]
            if chunk.isEmpty || offset + Int64(chunk.count) >= size {
                let finish = URLRequest(url: URL(string: DropboxSource.content + "files/upload_session/finish")!, method: "POST", headers: [
                    "Dropbox-API-Arg": try DropboxSource.headerJSON(["cursor": cursor, "commit": commit]),
                    "Content-Type": "application/octet-stream",
                ], body: chunk)
                _ = try await api.data(finish)
                return
            }
            let append = URLRequest(url: URL(string: DropboxSource.content + "files/upload_session/append_v2")!, method: "POST", headers: [
                "Dropbox-API-Arg": try DropboxSource.headerJSON(["cursor": cursor, "close": false]),
                "Content-Type": "application/octet-stream",
            ], body: chunk)
            _ = try await api.data(append)
            offset += Int64(chunk.count)
        }
    }

    public func delete(_ item: SourceItem) async throws {
        _ = try await call("files/delete_v2", ["path": item.path])
    }

    public func rename(_ item: SourceItem, to newName: String) async throws {
        let parent = PathUtils.parent(item.path)
        _ = try await call("files/move_v2", ["from_path": item.path, "to_path": (parent == "/" ? "" : parent) + "/" + newName])
    }

    public func createFolder(named name: String, in container: SourceItem?) async throws {
        _ = try await call("files/create_folder_v2", ["path": (container?.path ?? rootPath) + "/" + name, "autorename": true])
    }
}

// MARK: - Google Drive

/// Google Drive (API v3). `config.basePath`: optional folder id (default "root"). URIs: `gdrive://<sourceId>/<fileId>`.
public final class GoogleDriveSource: MusicSource {
    public let config: SourceConfig
    public var capabilities: SourceCapabilities { SourceCapabilities.fileServer.union(.search) }
    private let api: CloudHTTP
    private static let base = "https://www.googleapis.com/drive/v3/"
    private static let folderMime = "application/vnd.google-apps.folder"
    private static let shortcutMime = "application/vnd.google-apps.shortcut"
    private static let fields = "nextPageToken,files(id,name,mimeType,size,modifiedTime,shortcutDetails)"

    public init(config: SourceConfig, secrets: SourceSecrets, credentials: CredentialStore) throws {
        self.config = config
        api = CloudHTTP(session: try cloudSession(config, secrets, credentials: credentials))
    }

    private var rootID: String {
        let base = config.basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return base.isEmpty ? "root" : base
    }

    private func url(_ path: String, _ query: [String: String]) -> URL {
        var components = URLComponents(string: GoogleDriveSource.base + path)!
        components.setQuery(query)
        return components.url!
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }

    private func item(_ file: [String: Any]) -> SourceItem? {
        guard var id = JSONRead.string(file, "id"), let name = JSONRead.string(file, "name") else { return nil }
        var mime = JSONRead.string(file, "mimeType") ?? ""
        if mime == GoogleDriveSource.shortcutMime, let details = file["shortcutDetails"] as? [String: Any],
           let target = JSONRead.string(details, "targetId") {
            id = target
            mime = JSONRead.string(details, "targetMimeType") ?? ""
        }
        let isFolder = mime == GoogleDriveSource.folderMime
        if !isFolder && mime.hasPrefix("application/vnd.google-apps.") { return nil }
        return SourceItem(uri: idURI(config, id), name: name, kind: isFolder ? .folder : SourceItem.kind(forFileName: name), path: id,
                          size: isFolder ? nil : JSONRead.int64(file["size"]),
                          modified: JSONRead.string(file, "modifiedTime").flatMap(DateParsing.iso8601Date), mimeType: mime)
    }

    private func query(_ q: String, limit: Int = 100_000) async throws -> [SourceItem] {
        var items: [SourceItem] = []
        var pageToken: String?
        repeat {
            var parameters = ["q": q, "fields": GoogleDriveSource.fields, "pageSize": "1000", "supportsAllDrives": "true",
                              "includeItemsFromAllDrives": "true"]
            if let pageToken { parameters["pageToken"] = pageToken }
            let response = try await api.json(url("files", parameters))
            items += JSONRead.objects(response["files"]).compactMap(item)
            pageToken = response["nextPageToken"] as? String
        } while pageToken != nil && items.count < limit
        return items
    }

    public func connect() async throws {
        _ = try await api.json(url("files/\(rootID)", ["fields": "id", "supportsAllDrives": "true"]))
    }

    public func list(_ container: SourceItem?) async throws -> [SourceItem] {
        let parent = GoogleDriveSource.escape(container?.path ?? rootID)
        return try await query("'\(parent)' in parents and trashed = false").sortedForBrowsing()
    }

    public func search(_ text: String) async throws -> [SourceItem] {
        let needle = GoogleDriveSource.escape(text)
        return try await query("name contains '\(needle)' and trashed = false and (mimeType contains 'audio/' or mimeType = '\(GoogleDriveSource.folderMime)')",
                               limit: 300)
    }

    private func mediaRequest(_ uri: String) throws -> URLRequest {
        let id = try itemID(uri, scheme: "gdrive")
        return URLRequest(url: url("files/\(id)", ["alt": "media", "supportsAllDrives": "true"]))
    }

    public func streamURL(for uri: String) async throws -> RemoteResource? {
        let request = try mediaRequest(uri)
        return RemoteResource(url: request.url!, headers: try await api.bearerHeaders())
    }

    public func download(uri: String, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try await api.download(try mediaRequest(uri), to: destination, progress: progress)
    }

    public func upload(from localURL: URL, to container: SourceItem?, fileName: String) async throws {
        let data = try Data(contentsOf: localURL, options: .mappedIfSafe)
        let mime = PathUtils.mimeType(forExtension: PathUtils.fileExtension(fileName))
        var components = URLComponents(string: "https://www.googleapis.com/upload/drive/v3/files")!
        components.setQuery(["uploadType": "resumable", "supportsAllDrives": "true"])
        let metadata = try JSONSerialization.data(withJSONObject: ["name": fileName, "parents": [container?.path ?? rootID]])
        let start = URLRequest(url: components.url!, method: "POST", headers: [
            "Content-Type": "application/json; charset=UTF-8", "X-Upload-Content-Type": mime, "X-Upload-Content-Length": String(data.count),
        ], body: metadata)
        let (_, response) = try await api.data(start)
        guard let location = response.value(forHTTPHeaderField: "Location"), let uploadURL = URL(string: location) else {
            throw MuurError.protocolError("Google Drive did not return an upload URL")
        }
        _ = try await api.data(URLRequest(url: uploadURL, method: "PUT", headers: ["Content-Type": mime], body: data))
    }

    public func delete(_ item: SourceItem) async throws {
        _ = try await api.json(url("files/\(item.path)", ["supportsAllDrives": "true"]), method: "PATCH", body: ["trashed": true])
    }

    public func rename(_ item: SourceItem, to newName: String) async throws {
        _ = try await api.json(url("files/\(item.path)", ["supportsAllDrives": "true"]), method: "PATCH", body: ["name": newName])
    }

    public func createFolder(named name: String, in container: SourceItem?) async throws {
        _ = try await api.json(url("files", ["supportsAllDrives": "true"]), method: "POST", body: [
            "name": name, "mimeType": GoogleDriveSource.folderMime, "parents": [container?.path ?? rootID],
        ])
    }
}

// MARK: - OneDrive

/// OneDrive personal / business through Microsoft Graph. `config.basePath`: optional folder item id.
/// URIs: `onedrive://<sourceId>/<itemId>`. Graph's audio facet pre-fills track metadata.
public final class OneDriveSource: MusicSource {
    public let config: SourceConfig
    public var capabilities: SourceCapabilities { SourceCapabilities.fileServer.union([.search, .directURL]) }
    private let api: CloudHTTP
    private static let drive = "https://graph.microsoft.com/v1.0/me/drive/"
    private static let select = "id,name,size,folder,file,audio,lastModifiedDateTime,remoteItem"

    public init(config: SourceConfig, secrets: SourceSecrets, credentials: CredentialStore) throws {
        self.config = config
        api = CloudHTTP(session: try cloudSession(config, secrets, credentials: credentials))
    }

    private var rootID: String? {
        let base = config.basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return base.isEmpty ? nil : base
    }

    private func itemPath(_ id: String?) -> String {
        id.map { "items/\($0)" } ?? "root"
    }

    private func item(_ entry: [String: Any]) -> SourceItem? {
        guard let id = JSONRead.string(entry, "id"), let name = JSONRead.string(entry, "name") else { return nil }
        let isFolder = entry["folder"] != nil || (entry["remoteItem"] as? [String: Any])?["folder"] != nil
        let modified = JSONRead.string(entry, "lastModifiedDateTime").flatMap(DateParsing.iso8601Date)
        let size = JSONRead.int64(entry["size"])
        var track: Track?
        if !isFolder, let audio = entry["audio"] as? [String: Any] {
            var value = Track(sourceURI: idURI(config, id), sourceID: config.id.uuidString, folderPath: config.name, fileName: name,
                              title: JSONRead.string(audio, "title") ?? PathUtils.titleFromFileName(name),
                              artist: JSONRead.string(audio, "artist") ?? "", album: JSONRead.string(audio, "album") ?? "",
                              albumArtist: JSONRead.string(audio, "albumArtist") ?? "", genre: JSONRead.string(audio, "genre") ?? "",
                              composer: JSONRead.string(audio, "composers") ?? "", year: JSONRead.int(audio["year"]),
                              trackNumber: JSONRead.int(audio["track"]), trackTotal: JSONRead.int(audio["trackCount"]),
                              discNumber: JSONRead.int(audio["disc"]), discTotal: JSONRead.int(audio["discCount"]),
                              fileModified: modified, duration: (JSONRead.double(audio["duration"]) ?? 0) / 1000,
                              bitrate: JSONRead.int(audio["bitrate"]) ?? 0, fileSize: size ?? 0)
            value.codec = MetadataReader.normalizeCodec(nil, fileExtension: PathUtils.fileExtension(name))
            track = value
        }
        return SourceItem(uri: idURI(config, id), name: name, kind: isFolder ? .folder : SourceItem.kind(forFileName: name), path: id,
                          size: isFolder ? nil : size, modified: modified, track: track,
                          childCount: JSONRead.int((entry["folder"] as? [String: Any])?["childCount"]))
    }

    private func page(_ start: URL) async throws -> [SourceItem] {
        var next: URL? = start
        var items: [SourceItem] = []
        while let url = next {
            let response = try await api.json(url)
            items += JSONRead.objects(response["value"]).compactMap(item)
            next = (response["@odata.nextLink"] as? String).flatMap(URL.init(string:))
        }
        return items
    }

    public func connect() async throws {
        _ = try await api.json(URL(string: OneDriveSource.drive + itemPath(rootID) + "?$select=id")!)
    }

    public func list(_ container: SourceItem?) async throws -> [SourceItem] {
        let path = itemPath(container?.path ?? rootID)
        var components = URLComponents(string: OneDriveSource.drive + path + "/children")!
        components.queryItems = [URLQueryItem(name: "$top", value: "1000"), URLQueryItem(name: "$select", value: OneDriveSource.select)]
        return try await page(components.url!).sortedForBrowsing()
    }

    public func search(_ text: String) async throws -> [SourceItem] {
        let escaped = text.replacingOccurrences(of: "'", with: "''")
        let encoded = PathUtils.rfc3986Encode(escaped)
        guard let url = URL(string: OneDriveSource.drive + "root/search(q='\(encoded)')?$top=200&$select=\(OneDriveSource.select)") else { return [] }
        let response = try await api.json(url)
        return JSONRead.objects(response["value"]).compactMap(item)
    }

    public func streamURL(for uri: String) async throws -> RemoteResource? {
        let id = try itemID(uri, scheme: "onedrive")
        let response = try await api.json(URL(string: OneDriveSource.drive + "items/\(id)?$select=id,@microsoft.graph.downloadUrl")!)
        guard let link = response["@microsoft.graph.downloadUrl"] as? String, let url = URL(string: link) else { throw MuurError.notFound(uri) }
        return RemoteResource(url: url)
    }

    public func download(uri: String, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        guard let resource = try await streamURL(for: uri) else { throw MuurError.notFound(uri) }
        try await api.http.download(URLRequest(url: resource.url), to: destination, progress: progress)
    }

    public func upload(from localURL: URL, to container: SourceItem?, fileName: String) async throws {
        let parent = itemPath(container?.path ?? rootID)
        let encodedName = PathUtils.rfc3986Encode(fileName)
        let size = ((try? FileManager.default.attributesOfItem(atPath: localURL.path))?[.size] as? NSNumber)?.int64Value ?? 0
        if size <= 4 * 1024 * 1024 {
            let url = URL(string: OneDriveSource.drive + parent + ":/\(encodedName):/content?@microsoft.graph.conflictBehavior=rename")!
            _ = try await api.data(URLRequest(url: url, method: "PUT", headers: ["Content-Type": "application/octet-stream"],
                                              body: try Data(contentsOf: localURL)))
            return
        }
        let sessionURL = URL(string: OneDriveSource.drive + parent + ":/\(encodedName):/createUploadSession")!
        let session = try await api.json(sessionURL, method: "POST", body: ["item": ["@microsoft.graph.conflictBehavior": "rename"]])
        guard let uploadText = session["uploadUrl"] as? String, let uploadURL = URL(string: uploadText) else {
            throw MuurError.protocolError("OneDrive did not return an upload URL")
        }
        let handle = try FileHandle(forReadingFrom: localURL)
        defer { try? handle.close() }
        let chunkSize = 320 * 1024 * 32
        var offset: Int64 = 0
        while offset < size {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            let end = offset + Int64(chunk.count) - 1
            // The pre-authenticated upload URL must not receive the Authorization header.
            _ = try await api.http.data(for: URLRequest(url: uploadURL, method: "PUT", headers: [
                "Content-Range": "bytes \(offset)-\(end)/\(size)", "Content-Length": String(chunk.count),
            ], body: chunk))
            offset = end + 1
        }
    }

    public func delete(_ item: SourceItem) async throws {
        _ = try await api.data(URLRequest(url: URL(string: OneDriveSource.drive + "items/\(item.path)")!, method: "DELETE"))
    }

    public func rename(_ item: SourceItem, to newName: String) async throws {
        _ = try await api.json(URL(string: OneDriveSource.drive + "items/\(item.path)")!, method: "PATCH", body: ["name": newName])
    }

    public func createFolder(named name: String, in container: SourceItem?) async throws {
        let parent = itemPath(container?.path ?? rootID)
        _ = try await api.json(URL(string: OneDriveSource.drive + parent + "/children")!, method: "POST", body: [
            "name": name, "folder": [String: Any](), "@microsoft.graph.conflictBehavior": "rename",
        ])
    }
}

// MARK: - Box

/// Box (Content API 2.0). `config.basePath`: optional folder id (default "0"). Item paths are `d<id>` / `f<id>`.
/// URIs: `box://<sourceId>/f<fileId>`.
public final class BoxSource: MusicSource {
    public let config: SourceConfig
    public var capabilities: SourceCapabilities { SourceCapabilities.fileServer.union(.search) }
    private let api: CloudHTTP
    private static let base = "https://api.box.com/2.0/"
    private static let fields = "id,type,name,size,modified_at"

    public init(config: SourceConfig, secrets: SourceSecrets, credentials: CredentialStore) throws {
        self.config = config
        api = CloudHTTP(session: try cloudSession(config, secrets, credentials: credentials))
    }

    private var rootFolder: String {
        let base = config.basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return base.isEmpty ? "0" : base
    }

    private func folderID(_ container: SourceItem?) -> String {
        guard let path = container?.path, path.hasPrefix("d") else { return rootFolder }
        return String(path.dropFirst())
    }

    private func item(_ entry: [String: Any]) -> SourceItem? {
        guard let id = JSONRead.string(entry, "id"), let name = JSONRead.string(entry, "name") else { return nil }
        let type = JSONRead.string(entry, "type")
        guard type == "folder" || type == "file" else { return nil }
        let isFolder = type == "folder"
        let path = (isFolder ? "d" : "f") + id
        return SourceItem(uri: idURI(config, path), name: name, kind: isFolder ? .folder : SourceItem.kind(forFileName: name), path: path,
                          size: isFolder ? nil : JSONRead.int64(entry["size"]),
                          modified: JSONRead.string(entry, "modified_at").flatMap(DateParsing.iso8601Date))
    }

    public func connect() async throws {
        _ = try await api.json(URL(string: BoxSource.base + "folders/\(rootFolder)?fields=id")!)
    }

    public func list(_ container: SourceItem?) async throws -> [SourceItem] {
        let id = folderID(container)
        var items: [SourceItem] = []
        var offset = 0
        while true {
            let response = try await api.json(URL(string: BoxSource.base + "folders/\(id)/items?fields=\(BoxSource.fields)&limit=1000&offset=\(offset)")!)
            let entries = JSONRead.objects(response["entries"])
            items += entries.compactMap(item)
            offset += entries.count
            let total = JSONRead.int(response["total_count"]) ?? 0
            if entries.isEmpty || offset >= total { break }
        }
        return items.sortedForBrowsing()
    }

    public func search(_ text: String) async throws -> [SourceItem] {
        var components = URLComponents(string: BoxSource.base + "search")!
        components.setQuery(["query": text, "limit": "200", "fields": BoxSource.fields, "ancestor_folder_ids": rootFolder])
        let response = try await api.json(components.url!)
        return JSONRead.objects(response["entries"]).compactMap(item)
    }

    private func fileID(_ uri: String) throws -> String {
        let path = try itemID(uri, scheme: "box")
        guard path.hasPrefix("f") else { throw MuurError.invalidData("Not a Box file") }
        return String(path.dropFirst())
    }

    public func streamURL(for uri: String) async throws -> RemoteResource? {
        RemoteResource(url: URL(string: BoxSource.base + "files/\(try fileID(uri))/content")!, headers: try await api.bearerHeaders())
    }

    public func download(uri: String, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try await api.download(URLRequest(url: URL(string: BoxSource.base + "files/\(try fileID(uri))/content")!), to: destination, progress: progress)
    }

    public func upload(from localURL: URL, to container: SourceItem?, fileName: String) async throws {
        var form = MultipartForm()
        let attributes = try JSONSerialization.data(withJSONObject: ["name": fileName, "parent": ["id": folderID(container)]])
        form.addField("attributes", value: String(decoding: attributes, as: UTF8.self))
        form.addFile("file", fileName: fileName, mimeType: PathUtils.mimeType(forExtension: PathUtils.fileExtension(fileName)),
                     data: try Data(contentsOf: localURL, options: .mappedIfSafe))
        let request = URLRequest(url: URL(string: "https://upload.box.com/api/2.0/files/content")!, method: "POST",
                                 headers: ["Content-Type": form.contentType], body: form.finalized())
        _ = try await api.data(request)
    }

    private func endpoint(for item: SourceItem) -> String {
        let id = String(item.path.dropFirst())
        return item.path.hasPrefix("d") ? "folders/\(id)" : "files/\(id)"
    }

    public func delete(_ item: SourceItem) async throws {
        let suffix = item.path.hasPrefix("d") ? "?recursive=true" : ""
        _ = try await api.data(URLRequest(url: URL(string: BoxSource.base + endpoint(for: item) + suffix)!, method: "DELETE"))
    }

    public func rename(_ item: SourceItem, to newName: String) async throws {
        _ = try await api.json(URL(string: BoxSource.base + endpoint(for: item))!, method: "PUT", body: ["name": newName])
    }

    public func createFolder(named name: String, in container: SourceItem?) async throws {
        _ = try await api.json(URL(string: BoxSource.base + "folders")!, method: "POST", body: ["name": name, "parent": ["id": folderID(container)]])
    }
}

// MARK: - pCloud

/// pCloud. The API host (US `api.pcloud.com` / EU `eapi.pcloud.com`) comes from the sign-in redirect.
/// `config.basePath`: optional folder id (default "0"). Item paths are `d<id>` / `f<id>`. URIs: `pcloud://<sourceId>/f<fileId>`.
public final class PCloudSource: MusicSource {
    public let config: SourceConfig
    public var capabilities: SourceCapabilities { SourceCapabilities.fileServer.union([.search, .directURL]) }
    private let api: CloudHTTP

    public init(config: SourceConfig, secrets: SourceSecrets, credentials: CredentialStore) throws {
        self.config = config
        api = CloudHTTP(session: try cloudSession(config, secrets, credentials: credentials))
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()
    private static let dateLock = NSLock()

    static func parseDate(_ text: String) -> Date? {
        dateLock.lock(); defer { dateLock.unlock() }
        return dateFormatter.date(from: text)
    }

    private var rootFolder: String {
        let base = config.basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return base.isEmpty ? "0" : base
    }

    private func folderID(_ container: SourceItem?) -> String {
        guard let path = container?.path, path.hasPrefix("d") else { return rootFolder }
        return String(path.dropFirst())
    }

    private func call(_ method: String, _ parameters: [String: String], httpMethod: String = "GET", body: Data? = nil,
                      contentType: String? = nil) async throws -> [String: Any] {
        let host = await api.session.extra("hostname") ?? "api.pcloud.com"
        var components = URLComponents(string: "https://\(host)/\(method)")!
        components.setQuery(parameters)
        var headers = ["Accept": "application/json"]
        if let contentType { headers["Content-Type"] = contentType }
        let response = try await api.json(URLRequest(url: components.url!, method: httpMethod, headers: headers, body: body))
        let result = JSONRead.int(response["result"]) ?? 0
        guard result == 0 else {
            let message = JSONRead.string(response, "error") ?? "pCloud error \(result)"
            if result == 1000 || result == 2000 || result == 2094 { throw MuurError.authenticationFailed(message) }
            if result == 2005 || result == 2009 { throw MuurError.notFound(message) }
            throw MuurError.protocolError(message)
        }
        return response
    }

    private func item(_ entry: [String: Any]) -> SourceItem? {
        guard let name = JSONRead.string(entry, "name") else { return nil }
        let isFolder = JSONRead.bool(entry["isfolder"])
        guard let id = isFolder ? JSONRead.string(entry, "folderid") : JSONRead.string(entry, "fileid") else { return nil }
        let path = (isFolder ? "d" : "f") + id
        return SourceItem(uri: idURI(config, path), name: name, kind: isFolder ? .folder : SourceItem.kind(forFileName: name), path: path,
                          size: isFolder ? nil : JSONRead.int64(entry["size"]),
                          modified: JSONRead.string(entry, "modified").flatMap(PCloudSource.parseDate),
                          mimeType: JSONRead.string(entry, "contenttype"))
    }

    public func connect() async throws {
        _ = try await call("listfolder", ["folderid": rootFolder, "nofiles": "1"])
    }

    public func list(_ container: SourceItem?) async throws -> [SourceItem] {
        let response = try await call("listfolder", ["folderid": folderID(container)])
        let contents = JSONRead.objects((response["metadata"] as? [String: Any])?["contents"])
        return contents.compactMap(item).sortedForBrowsing()
    }

    public func search(_ text: String) async throws -> [SourceItem] {
        let needle = text.lowercased()
        let response = try await call("listfolder", ["folderid": rootFolder, "recursive": "1"])
        var results: [SourceItem] = []
        var stack = [response["metadata"] as? [String: Any] ?? [:]]
        while let folder = stack.popLast(), results.count < 300 {
            for entry in JSONRead.objects(folder["contents"]) {
                if JSONRead.bool(entry["isfolder"]) { stack.append(entry) }
                if let name = JSONRead.string(entry, "name"), name.lowercased().contains(needle), let found = item(entry) {
                    results.append(found)
                }
            }
        }
        return results
    }

    private func fileID(_ uri: String) throws -> String {
        let path = try itemID(uri, scheme: "pcloud")
        guard path.hasPrefix("f") else { throw MuurError.invalidData("Not a pCloud file") }
        return String(path.dropFirst())
    }

    public func streamURL(for uri: String) async throws -> RemoteResource? {
        let response = try await call("getfilelink", ["fileid": try fileID(uri), "forcedownload": "0"])
        guard let hosts = response["hosts"] as? [String], let host = hosts.first, let path = response["path"] as? String,
              let url = URL(string: "https://\(host)\(path)") else { throw MuurError.notFound(uri) }
        return RemoteResource(url: url)
    }

    public func download(uri: String, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        guard let resource = try await streamURL(for: uri) else { throw MuurError.notFound(uri) }
        try await api.http.download(URLRequest(url: resource.url), to: destination, progress: progress)
    }

    public func upload(from localURL: URL, to container: SourceItem?, fileName: String) async throws {
        var form = MultipartForm()
        form.addFile("file", fileName: fileName, mimeType: PathUtils.mimeType(forExtension: PathUtils.fileExtension(fileName)),
                     data: try Data(contentsOf: localURL, options: .mappedIfSafe))
        _ = try await call("uploadfile", ["folderid": folderID(container), "filename": fileName, "nopartial": "1", "renameifexists": "1"],
                           httpMethod: "POST", body: form.finalized(), contentType: form.contentType)
    }

    public func delete(_ item: SourceItem) async throws {
        let id = String(item.path.dropFirst())
        if item.path.hasPrefix("d") {
            _ = try await call("deletefolderrecursive", ["folderid": id])
        } else {
            _ = try await call("deletefile", ["fileid": id])
        }
    }

    public func rename(_ item: SourceItem, to newName: String) async throws {
        let id = String(item.path.dropFirst())
        if item.path.hasPrefix("d") {
            _ = try await call("renamefolder", ["folderid": id, "toname": newName])
        } else {
            _ = try await call("renamefile", ["fileid": id, "toname": newName])
        }
    }

    public func createFolder(named name: String, in container: SourceItem?) async throws {
        _ = try await call("createfolder", ["folderid": folderID(container), "name": name])
    }
}
