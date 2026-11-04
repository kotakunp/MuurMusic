import Foundation

/// Identity sent to media servers.
public enum MediaServerIdentity {
    private static let key = "app.muur.deviceID"

    /// Stable per-installation device id.
    public static var deviceID: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: key) { return existing }
        let id = UUID().uuidString
        defaults.set(id, forKey: key)
        return id
    }

    public static var deviceName: String {
        #if os(iOS)
        return "MuurMusic iOS"
        #else
        return "MuurMusic macOS"
        #endif
    }

    public static let product = "MuurMusic"
    public static let version = "1.0"

    /// Base URL from `config.host` ("host", "host:port" or a full URL) plus `port` / `useTLS`.
    public static func baseURL(_ config: SourceConfig) throws -> URL {
        var host = config.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw MuurError.notConfigured("\(config.kind.displayName) server address") }
        if !host.contains("://") { host = (config.useTLS ? "https://" : "http://") + host }
        guard var components = URLComponents(string: host), components.host != nil else {
            throw MuurError.invalidData("Invalid server address")
        }
        if let port = config.port { components.port = port } else if components.port == nil, !config.useTLS, let port = config.kind.defaultPort,
                                                                      !config.host.contains("://") {
            components.port = port
        }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url else { throw MuurError.invalidData("Invalid server address") }
        return url
    }
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw MuurError.invalidData("Expected a JSON object")
    }
    return object
}

// MARK: - Subsonic

/// Subsonic-compatible servers (Navidrome, Airsonic, Gonic, Ampache...).
///
/// `config.host` = server URL, `username` + `SourceSecrets.password` (token + salt auth), or
/// `SourceSecrets.token` = OpenSubsonic API key. Option `subsonicLegacyAuth` = "true" sends the hex-encoded password.
/// URIs: `subsonic://<sourceId>/<songId>`.
public final class SubsonicSource: MusicSource {
    public let config: SourceConfig
    public var capabilities: SourceCapabilities { [.browse, .search, .directURL, .library] }
    private let baseURL: URL
    private let password: String
    private let apiKey: String?
    private let http: HTTPClient

    public init(config: SourceConfig, secrets: SourceSecrets) throws {
        self.config = config
        baseURL = try MediaServerIdentity.baseURL(config)
        password = secrets.password ?? ""
        apiKey = secrets.token.flatMap { $0.isEmpty ? nil : $0 }
        guard apiKey != nil || !config.username.isEmpty else { throw MuurError.notConfigured("Subsonic user name") }
        http = HTTPClient(allowInsecureTLS: config.allowInsecureTLS)
    }

    func authItems() -> [URLQueryItem] {
        var items = [URLQueryItem(name: "v", value: "1.16.1"), URLQueryItem(name: "c", value: MediaServerIdentity.product),
                     URLQueryItem(name: "f", value: "json")]
        if let apiKey {
            items.append(URLQueryItem(name: "apiKey", value: apiKey))
        } else if config.flag(SourceConfig.OptionKey.subsonicLegacyAuth) {
            let hex = Data(password.utf8).map { String(format: "%02x", $0) }.joined()
            items += [URLQueryItem(name: "u", value: config.username), URLQueryItem(name: "p", value: "enc:" + hex)]
        } else {
            let salt = Hashing.randomToken(length: 12)
            items += [URLQueryItem(name: "u", value: config.username), URLQueryItem(name: "t", value: Hashing.md5Hex(password + salt)),
                      URLQueryItem(name: "s", value: salt)]
        }
        return items
    }

    func endpoint(_ name: String, _ parameters: [String: String] = [:]) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent("rest").appendingPathComponent(name), resolvingAgainstBaseURL: false)!
        components.queryItems = authItems() + parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // "+" in tokens must be escaped; URLComponents leaves it as is.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    private func call(_ name: String, _ parameters: [String: String] = [:]) async throws -> [String: Any] {
        let data = try await http.data(from: endpoint(name, parameters))
        guard let response = try jsonObject(data)["subsonic-response"] as? [String: Any] else {
            throw MuurError.invalidData("Not a Subsonic response")
        }
        if response["status"] as? String != "ok" {
            let error = response["error"] as? [String: Any]
            let code = JSONRead.int(error?["code"]) ?? 0
            let message = error?["message"] as? String ?? "Subsonic error \(code)"
            if code == 40 || code == 41 || code == 44 { throw MuurError.authenticationFailed(message) }
            if code == 70 { throw MuurError.notFound(message) }
            throw MuurError.protocolError(message)
        }
        return response
    }

    private func uri(_ id: String) -> String {
        SourceURI(scheme: "subsonic", authority: config.id.uuidString, path: id).description
    }

    private func coverURL(_ id: String?) -> URL? {
        guard let id, !id.isEmpty else { return nil }
        return endpoint("getCoverArt", ["id": id, "size": "600"])
    }

    func track(_ song: [String: Any]) -> Track? {
        guard let id = JSONRead.string(song, "id") else { return nil }
        let suffix = JSONRead.string(song, "suffix") ?? ""
        let title = JSONRead.string(song, "title") ?? "Untitled"
        let fileName = (JSONRead.string(song, "path").map(PathUtils.lastComponent)) ?? (title + (suffix.isEmpty ? "" : "." + suffix))
        var track = Track(sourceURI: uri(id), sourceID: config.id.uuidString, folderPath: config.name, fileName: fileName, title: title,
                          artist: JSONRead.string(song, "artist") ?? "", album: JSONRead.string(song, "album") ?? "",
                          albumArtist: JSONRead.string(song, "displayAlbumArtist") ?? "", genre: JSONRead.string(song, "genre") ?? "",
                          composer: JSONRead.string(song, "displayComposer") ?? "", year: JSONRead.int(song["year"]),
                          trackNumber: JSONRead.int(song["track"]), discNumber: JSONRead.int(song["discNumber"]),
                          bpm: JSONRead.int(song["bpm"]).flatMap { $0 > 0 ? $0 : nil }, rating: JSONRead.int(song["userRating"]) ?? 0,
                          playCount: JSONRead.int(song["playCount"]) ?? 0,
                          dateAdded: JSONRead.string(song, "created").flatMap(DateParsing.iso8601Date) ?? Date(),
                          favorite: song["starred"] != nil, duration: JSONRead.double(song["duration"]) ?? 0,
                          bitrate: JSONRead.int(song["bitRate"]) ?? 0, sampleRate: JSONRead.double(song["samplingRate"]) ?? 0,
                          bitDepth: JSONRead.int(song["bitDepth"]) ?? 0, channels: JSONRead.int(song["channelCount"]) ?? 0,
                          fileSize: JSONRead.int64(song["size"]) ?? 0)
        track.codec = MetadataReader.normalizeCodec(nil, fileExtension: suffix)
        if let replayGain = song["replayGain"] as? [String: Any] {
            track.replayGainTrackGain = JSONRead.double(replayGain["trackGain"])
            track.replayGainTrackPeak = JSONRead.double(replayGain["trackPeak"])
            track.replayGainAlbumGain = JSONRead.double(replayGain["albumGain"])
            track.replayGainAlbumPeak = JSONRead.double(replayGain["albumPeak"])
        }
        track.musicBrainzRecordingID = JSONRead.string(song, "musicBrainzId")
        return track
    }

    private func songItem(_ song: [String: Any]) -> SourceItem? {
        guard let track = self.track(song) else { return nil }
        return SourceItem(uri: track.sourceURI, name: track.title, kind: .audio, path: JSONRead.string(song, "id") ?? "",
                          size: track.fileSize, mimeType: JSONRead.string(song, "contentType"), track: track,
                          artworkURL: coverURL(JSONRead.string(song, "coverArt")), subtitle: track.artist)
    }

    private func folder(_ path: String, _ name: String, subtitle: String? = nil, cover: String? = nil, count: Int? = nil) -> SourceItem {
        SourceItem(uri: uri(path), name: name, kind: .folder, path: path, artworkURL: coverURL(cover), childCount: count, subtitle: subtitle)
    }

    private func albumItem(_ album: [String: Any]) -> SourceItem? {
        guard let id = JSONRead.string(album, "id") else { return nil }
        let year = JSONRead.int(album["year"]).map { " (\($0))" } ?? ""
        return folder("album:" + id, (JSONRead.string(album, "name") ?? JSONRead.string(album, "title") ?? "Album") + year,
                      subtitle: JSONRead.string(album, "artist"), cover: JSONRead.string(album, "coverArt"),
                      count: JSONRead.int(album["songCount"]))
    }

    public func connect() async throws {
        _ = try await call("ping")
    }

    public func list(_ container: SourceItem?) async throws -> [SourceItem] {
        guard let path = container?.path, !path.isEmpty else {
            return [folder("artists", "Artists"), folder("albums", "Albums"), folder("recent", "Recently Added"),
                    folder("playlists", "Playlists"), folder("folders", "Folders")]
        }
        let parts = path.split(separator: ":", maxSplits: 1).map(String.init)
        let id = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "artists":
            let response = try await call("getArtists")
            let indexes = JSONRead.objects((response["artists"] as? [String: Any])?["index"])
            return indexes.flatMap { JSONRead.objects($0["artist"]) }.compactMap { artist in
                guard let artistID = JSONRead.string(artist, "id") else { return nil }
                return folder("artist:" + artistID, JSONRead.string(artist, "name") ?? "Artist",
                              subtitle: JSONRead.int(artist["albumCount"]).map { "\($0) albums" }, cover: JSONRead.string(artist, "coverArt"))
            }
        case "artist":
            let response = try await call("getArtist", ["id": id])
            return JSONRead.objects((response["artist"] as? [String: Any])?["album"]).compactMap(albumItem)
        case "albums", "recent":
            var items: [SourceItem] = []
            var offset = 0
            let pageSize = 500
            while true {
                let response = try await call("getAlbumList2", ["type": parts[0] == "recent" ? "newest" : "alphabeticalByName",
                                                                "size": String(pageSize), "offset": String(offset)])
                let albums = JSONRead.objects((response["albumList2"] as? [String: Any])?["album"])
                items += albums.compactMap(albumItem)
                offset += albums.count
                if albums.count < pageSize || parts[0] == "recent" { break }
            }
            return items
        case "album":
            let response = try await call("getAlbum", ["id": id])
            return JSONRead.objects((response["album"] as? [String: Any])?["song"]).compactMap(songItem)
        case "playlists":
            let response = try await call("getPlaylists")
            return JSONRead.objects((response["playlists"] as? [String: Any])?["playlist"]).compactMap { playlist in
                guard let playlistID = JSONRead.string(playlist, "id") else { return nil }
                return folder("playlist:" + playlistID, JSONRead.string(playlist, "name") ?? "Playlist",
                              subtitle: JSONRead.int(playlist["songCount"]).map { "\($0) songs" }, cover: JSONRead.string(playlist, "coverArt"))
            }
        case "playlist":
            let response = try await call("getPlaylist", ["id": id])
            return JSONRead.objects((response["playlist"] as? [String: Any])?["entry"]).compactMap(songItem)
        case "folders":
            let response = try await call("getIndexes")
            let indexes = JSONRead.objects((response["indexes"] as? [String: Any])?["index"])
            return indexes.flatMap { JSONRead.objects($0["artist"]) }.compactMap { entry in
                guard let dirID = JSONRead.string(entry, "id") else { return nil }
                return folder("dir:" + dirID, JSONRead.string(entry, "name") ?? "Folder")
            }
        case "dir":
            let response = try await call("getMusicDirectory", ["id": id])
            return JSONRead.objects((response["directory"] as? [String: Any])?["child"]).compactMap { child in
                if JSONRead.bool(child["isDir"]) {
                    guard let dirID = JSONRead.string(child, "id") else { return nil }
                    return folder("dir:" + dirID, JSONRead.string(child, "title") ?? "Folder", cover: JSONRead.string(child, "coverArt"))
                }
                return songItem(child)
            }
        default:
            return []
        }
    }

    public func search(_ text: String) async throws -> [SourceItem] {
        let response = try await call("search3", ["query": text, "artistCount": "20", "albumCount": "40", "songCount": "150"])
        let result = response["searchResult3"] as? [String: Any] ?? [:]
        let artists: [SourceItem] = JSONRead.objects(result["artist"]).compactMap { artist in
            guard let id = JSONRead.string(artist, "id") else { return nil }
            return folder("artist:" + id, JSONRead.string(artist, "name") ?? "Artist", subtitle: "Artist", cover: JSONRead.string(artist, "coverArt"))
        }
        return artists + JSONRead.objects(result["album"]).compactMap(albumItem) + JSONRead.objects(result["song"]).compactMap(songItem)
    }

    public func libraryTracks(progress: @escaping @Sendable (Int, Int) -> Void) async throws -> [Track]? {
        var tracks: [Track] = []
        var offset = 0
        let pageSize = 500
        while true {
            try Task.checkCancellation()
            let response = try await call("search3", ["query": "", "artistCount": "0", "albumCount": "0", "songCount": String(pageSize),
                                                      "songOffset": String(offset)])
            let songs = JSONRead.objects((response["searchResult3"] as? [String: Any])?["song"])
            tracks += songs.compactMap(track)
            offset += songs.count
            progress(tracks.count, 0)
            if songs.count < pageSize { break }
        }
        if !tracks.isEmpty { return tracks }
        // Servers that reject empty search queries: walk all albums.
        var albumOffset = 0
        while true {
            try Task.checkCancellation()
            let response = try await call("getAlbumList2", ["type": "alphabeticalByName", "size": "500", "offset": String(albumOffset)])
            let albums = JSONRead.objects((response["albumList2"] as? [String: Any])?["album"])
            for album in albums {
                guard let id = JSONRead.string(album, "id") else { continue }
                let detail = try await call("getAlbum", ["id": id])
                tracks += JSONRead.objects((detail["album"] as? [String: Any])?["song"]).compactMap(track)
                progress(tracks.count, 0)
            }
            albumOffset += albums.count
            if albums.count < 500 { break }
        }
        return tracks
    }

    public func streamURL(for uri: String) async throws -> RemoteResource? {
        RemoteResource(url: endpoint("stream", ["id": try itemID(uri), "format": "raw"]))
    }

    private func itemID(_ uri: String) throws -> String {
        guard let parsed = SourceURI.parse(uri), parsed.scheme == "subsonic" else { throw MuurError.invalidData("Not a Subsonic URI") }
        return parsed.path
    }

    public func download(uri: String, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try await http.download(URLRequest(url: endpoint("download", ["id": try itemID(uri)])), to: destination, progress: progress)
    }

    /// Reports a play to the server (scrobble).
    public func scrobble(uri: String, submission: Bool = true) async throws {
        _ = try await call("scrobble", ["id": try itemID(uri), "submission": submission ? "true" : "false"])
    }
}

// MARK: - Jellyfin / Emby

/// Jellyfin and Emby servers. `config.host` = server URL; `username` + `SourceSecrets.password` are exchanged
/// for an access token (`SourceSecrets.token`) on first connect. URIs: `jellyfin://<sourceId>/<itemId>`.
public final class JellyfinSource: MusicSource {
    public let config: SourceConfig
    public var capabilities: SourceCapabilities { [.browse, .search, .directURL, .library] }
    private let baseURL: URL
    private let http: HTTPClient
    private let credentials: CredentialStore
    private let password: String
    private let token: LockedValue<String?>
    private let userID: LockedValue<String?>
    private let isEmby: Bool

    public init(config: SourceConfig, secrets: SourceSecrets, credentials: CredentialStore) throws {
        self.config = config
        baseURL = try MediaServerIdentity.baseURL(config)
        http = HTTPClient(allowInsecureTLS: config.allowInsecureTLS)
        self.credentials = credentials
        password = secrets.password ?? ""
        token = LockedValue(secrets.token.flatMap { $0.isEmpty ? nil : $0 })
        userID = LockedValue(config.option(SourceConfig.OptionKey.userID))
        isEmby = config.kind == .emby
    }

    private func authorizationValue(token: String?) -> String {
        var value = "MediaBrowser Client=\"\(MediaServerIdentity.product)\", Device=\"\(MediaServerIdentity.deviceName)\", "
            + "DeviceId=\"\(MediaServerIdentity.deviceID)\", Version=\"\(MediaServerIdentity.version)\""
        if let token { value += ", Token=\"\(token)\"" }
        return value
    }

    private func headers(token: String?) -> [String: String] {
        var result = [isEmby ? "X-Emby-Authorization" : "Authorization": authorizationValue(token: token), "Accept": "application/json"]
        if let token { result["X-Emby-Token"] = token }
        return result
    }

    private func url(_ path: String, _ query: [String: String] = [:]) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.setQuery(query) }
        return components.url!
    }

    /// Signs in with user name and password; stores the token in the credential store.
    @discardableResult
    public func authenticate() async throws -> String {
        guard !config.username.isEmpty else { throw MuurError.notConfigured("\(config.kind.displayName) user name") }
        let body = try JSONSerialization.data(withJSONObject: ["Username": config.username, "Pw": password])
        var requestHeaders = headers(token: nil)
        requestHeaders["Content-Type"] = "application/json"
        let request = URLRequest(url: url("Users/AuthenticateByName"), method: "POST", headers: requestHeaders, body: body)
        let response = try jsonObject(try await http.data(for: request).0)
        guard let accessToken = response["AccessToken"] as? String else { throw MuurError.authenticationFailed("No access token") }
        token.set(accessToken)
        if let user = response["User"] as? [String: Any], let id = JSONRead.string(user, "Id") { userID.set(id) }
        try? credentials.update(for: config.id) { $0.token = accessToken }
        return accessToken
    }

    private func validToken() async throws -> String {
        if let existing = token.get() { return existing }
        return try await authenticate()
    }

    private func get(_ path: String, _ query: [String: String] = [:]) async throws -> [String: Any] {
        var accessToken = try await validToken()
        do {
            return try jsonObject(try await http.data(for: URLRequest(url: url(path, query), method: "GET", headers: headers(token: accessToken))).0)
        } catch MuurError.authenticationFailed(_) where !password.isEmpty {
            token.set(nil)
            accessToken = try await authenticate()
            return try jsonObject(try await http.data(for: URLRequest(url: url(path, query), method: "GET", headers: headers(token: accessToken))).0)
        }
    }

    private func getArray(_ path: String, _ query: [String: String] = [:]) async throws -> [[String: Any]] {
        var accessToken = try await validToken()
        let data: Data
        do {
            data = try await http.data(for: URLRequest(url: url(path, query), method: "GET", headers: headers(token: accessToken))).0
        } catch MuurError.authenticationFailed(_) where !password.isEmpty {
            accessToken = try await authenticate()
            data = try await http.data(for: URLRequest(url: url(path, query), method: "GET", headers: headers(token: accessToken))).0
        }
        return (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    private func currentUserID() async throws -> String {
        if let id = userID.get() { return id }
        let me = try await get("Users/Me")
        guard let id = JSONRead.string(me, "Id") else { throw MuurError.authenticationFailed("Unknown user") }
        userID.set(id)
        return id
    }

    private func uri(_ id: String) -> String {
        SourceURI(scheme: "jellyfin", authority: config.id.uuidString, path: id).description
    }

    private func imageURL(_ id: String?, tag: String?) -> URL? {
        guard let id, !id.isEmpty else { return nil }
        var query = ["maxHeight": "600", "quality": "90"]
        if let tag { query["tag"] = tag }
        return url("Items/\(id)/Images/Primary", query)
    }

    private static let trackFields = "MediaSources,Path,DateCreated,Genres,UserData,ParentId"

    func track(_ item: [String: Any]) -> Track? {
        guard let id = JSONRead.string(item, "Id") else { return nil }
        let source = JSONRead.objects(item["MediaSources"]).first ?? [:]
        let audio = JSONRead.objects(source["MediaStreams"]).first { JSONRead.string($0, "Type") == "Audio" } ?? [:]
        let container = (JSONRead.string(source, "Container") ?? JSONRead.string(item, "Container") ?? "").split(separator: ",").first.map(String.init) ?? ""
        let path = JSONRead.string(item, "Path") ?? JSONRead.string(source, "Path")
        let title = JSONRead.string(item, "Name") ?? "Untitled"
        let artists = (item["Artists"] as? [String]) ?? []
        let userData = item["UserData"] as? [String: Any] ?? [:]
        let ticks = JSONRead.double(item["RunTimeTicks"]) ?? JSONRead.double(source["RunTimeTicks"]) ?? 0
        var track = Track(sourceURI: uri(id), sourceID: config.id.uuidString, folderPath: config.name,
                          fileName: path.map(PathUtils.lastComponent) ?? title + (container.isEmpty ? "" : "." + container), title: title,
                          artist: artists.joined(separator: ", "), album: JSONRead.string(item, "Album") ?? "",
                          albumArtist: JSONRead.string(item, "AlbumArtist") ?? "",
                          genre: ((item["Genres"] as? [String]) ?? []).joined(separator: ", "),
                          year: JSONRead.int(item["ProductionYear"]), trackNumber: JSONRead.int(item["IndexNumber"]),
                          discNumber: JSONRead.int(item["ParentIndexNumber"]), playCount: JSONRead.int(userData["PlayCount"]) ?? 0,
                          dateAdded: JSONRead.string(item, "DateCreated").flatMap(DateParsing.iso8601Date) ?? Date(),
                          favorite: JSONRead.bool(userData["IsFavorite"]), duration: ticks / 10_000_000,
                          bitrate: (JSONRead.int(audio["BitRate"]) ?? JSONRead.int(source["Bitrate"]) ?? 0) / 1000,
                          sampleRate: JSONRead.double(audio["SampleRate"]) ?? 0, bitDepth: JSONRead.int(audio["BitDepth"]) ?? 0,
                          channels: JSONRead.int(audio["Channels"]) ?? 0, fileSize: JSONRead.int64(source["Size"]) ?? 0)
        track.codec = MetadataReader.normalizeCodec(JSONRead.string(audio, "Codec")?.uppercased(), fileExtension: container)
        if let gain = JSONRead.double(item["NormalizationGain"]) { track.replayGainTrackGain = gain }
        return track
    }

    private func audioItem(_ item: [String: Any]) -> SourceItem? {
        guard let track = self.track(item) else { return nil }
        let tags = item["ImageTags"] as? [String: Any]
        let ownTag = tags.flatMap { JSONRead.string($0, "Primary") }
        let artwork = ownTag != nil ? imageURL(JSONRead.string(item, "Id"), tag: ownTag)
            : imageURL(JSONRead.string(item, "AlbumId"), tag: JSONRead.string(item, "AlbumPrimaryImageTag"))
        return SourceItem(uri: track.sourceURI, name: track.title, kind: .audio, path: JSONRead.string(item, "Id") ?? "",
                          size: track.fileSize, track: track, artworkURL: artwork, subtitle: track.artist)
    }

    private func folderItem(_ path: String, _ item: [String: Any], subtitle: String? = nil) -> SourceItem? {
        guard let id = JSONRead.string(item, "Id") else { return nil }
        let tag = (item["ImageTags"] as? [String: Any]).flatMap { JSONRead.string($0, "Primary") }
        return SourceItem(uri: uri(path + id), name: JSONRead.string(item, "Name") ?? "", kind: .folder, path: path + id,
                          artworkURL: imageURL(id, tag: tag), childCount: JSONRead.int(item["ChildCount"]),
                          subtitle: subtitle ?? JSONRead.string(item, "AlbumArtist"))
    }

    private func virtualFolder(_ path: String, _ name: String) -> SourceItem {
        SourceItem(uri: uri(path), name: name, kind: .folder, path: path)
    }

    private func pagedItems(_ path: String, _ query: [String: String], progress: ((Int, Int) -> Void)? = nil) async throws -> [[String: Any]] {
        var all: [[String: Any]] = []
        var start = 0
        while true {
            try Task.checkCancellation()
            var parameters = query
            parameters["StartIndex"] = String(start)
            parameters["Limit"] = "500"
            let response = try await get(path, parameters)
            let items = JSONRead.objects(response["Items"])
            all += items
            start += items.count
            let total = JSONRead.int(response["TotalRecordCount"]) ?? 0
            progress?(all.count, total)
            if items.isEmpty || start >= total { break }
        }
        return all
    }

    public func connect() async throws {
        _ = try await validToken()
        _ = try await currentUserID()
    }

    public func list(_ container: SourceItem?) async throws -> [SourceItem] {
        let user = try await currentUserID()
        guard let path = container?.path, !path.isEmpty else {
            let views = JSONRead.objects(try await get("Users/\(user)/Views")["Items"])
            return views.compactMap { view in
                switch JSONRead.string(view, "CollectionType") {
                case "music": return folderItem("view:", view)
                case "playlists": return folderItem("playlists:", view)
                default: return nil
                }
            }
        }
        let parts = path.split(separator: ":", maxSplits: 1).map(String.init)
        let id = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "view":
            return [virtualFolder("albums:" + id, "Albums"), virtualFolder("artists:" + id, "Album Artists"),
                    virtualFolder("songs:" + id, "Songs")]
        case "albums":
            return try await pagedItems("Users/\(user)/Items", ["ParentId": id, "IncludeItemTypes": "MusicAlbum", "Recursive": "true",
                                                                "SortBy": "SortName", "Fields": "ChildCount"]).compactMap { folderItem("album:", $0) }
        case "artists":
            let response = try await get("Artists/AlbumArtists", ["ParentId": id, "UserId": user, "SortBy": "SortName", "Fields": "ChildCount"])
            return JSONRead.objects(response["Items"]).compactMap { folderItem("artist:", $0, subtitle: "Artist") }
        case "artist":
            return try await pagedItems("Users/\(user)/Items", ["AlbumArtistIds": id, "IncludeItemTypes": "MusicAlbum", "Recursive": "true",
                                                                "SortBy": "ProductionYear,SortName"]).compactMap { folderItem("album:", $0) }
        case "songs":
            return try await pagedItems("Users/\(user)/Items", ["ParentId": id, "IncludeItemTypes": "Audio", "Recursive": "true",
                                                                "SortBy": "SortName", "Fields": JellyfinSource.trackFields]).compactMap(audioItem)
        case "album":
            return try await pagedItems("Users/\(user)/Items", ["ParentId": id, "IncludeItemTypes": "Audio", "Recursive": "true",
                                                                "SortBy": "ParentIndexNumber,IndexNumber,SortName",
                                                                "Fields": JellyfinSource.trackFields]).compactMap(audioItem)
        case "playlists":
            return try await pagedItems("Users/\(user)/Items", ["ParentId": id, "SortBy": "SortName"]).compactMap { folderItem("playlist:", $0) }
        case "playlist":
            return try await pagedItems("Playlists/\(id)/Items", ["UserId": user, "Fields": JellyfinSource.trackFields]).compactMap(audioItem)
        default:
            return []
        }
    }

    public func search(_ text: String) async throws -> [SourceItem] {
        let user = try await currentUserID()
        let response = try await get("Users/\(user)/Items", ["SearchTerm": text, "IncludeItemTypes": "MusicAlbum,Audio", "Recursive": "true",
                                                              "Limit": "200", "Fields": JellyfinSource.trackFields])
        return JSONRead.objects(response["Items"]).compactMap { item in
            JSONRead.string(item, "Type") == "MusicAlbum" ? folderItem("album:", item) : audioItem(item)
        }
    }

    public func libraryTracks(progress: @escaping @Sendable (Int, Int) -> Void) async throws -> [Track]? {
        let user = try await currentUserID()
        let items = try await pagedItems("Users/\(user)/Items", ["IncludeItemTypes": "Audio", "Recursive": "true", "SortBy": "SortName",
                                                                 "Fields": JellyfinSource.trackFields], progress: { progress($0, $1) })
        return items.compactMap(track)
    }

    private func itemID(_ uri: String) throws -> String {
        guard let parsed = SourceURI.parse(uri), parsed.scheme == "jellyfin" else { throw MuurError.invalidData("Not a Jellyfin URI") }
        return parsed.path
    }

    public func streamURL(for uri: String) async throws -> RemoteResource? {
        let accessToken = try await validToken()
        let id = try itemID(uri)
        return RemoteResource(url: url("Audio/\(id)/stream", ["static": "true", "api_key": accessToken, "DeviceId": MediaServerIdentity.deviceID]))
    }

    public func download(uri: String, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let accessToken = try await validToken()
        let id = try itemID(uri)
        let request = URLRequest(url: url("Items/\(id)/Download", ["api_key": accessToken]), method: "GET", headers: headers(token: accessToken))
        do {
            try await http.download(request, to: destination, progress: progress)
        } catch MuurError.http(let status, _) where status == 404 || status == 405 {
            // Older Emby builds: fall back to the static stream.
            guard let stream = try await streamURL(for: uri) else { throw MuurError.notFound(uri) }
            try await http.download(URLRequest(url: stream.url), to: destination, progress: progress)
        }
    }
}

// MARK: - Plex

/// A Plex PIN used for the plex.tv sign-in flow.
public struct PlexPIN: Hashable, Sendable {
    public var id: Int
    public var code: String
}

/// A Plex Media Server available to the signed-in account.
public struct PlexServer: Hashable, Sendable, Identifiable {
    public struct Connection: Hashable, Sendable {
        public var uri: URL
        public var isLocal: Bool
        public var isRelay: Bool
    }

    public var id: String { clientIdentifier }
    public var name: String
    public var clientIdentifier: String
    public var accessToken: String
    public var connections: [Connection]
    public var isOwned: Bool
}

/// plex.tv PIN sign-in: create a PIN, open `authURL(for:)` in a browser, then `waitForToken`.
public struct PlexAuthenticator: Sendable {
    public let clientIdentifier: String
    private let http: HTTPClient

    public init(clientIdentifier: String = MediaServerIdentity.deviceID, http: HTTPClient = .shared) {
        self.clientIdentifier = clientIdentifier
        self.http = http
    }

    var headers: [String: String] {
        ["Accept": "application/json", "X-Plex-Product": MediaServerIdentity.product, "X-Plex-Version": MediaServerIdentity.version,
         "X-Plex-Client-Identifier": clientIdentifier, "X-Plex-Device-Name": MediaServerIdentity.deviceName,
         "X-Plex-Platform": MediaServerIdentity.deviceName.hasSuffix("iOS") ? "iOS" : "macOS"]
    }

    public func createPIN() async throws -> PlexPIN {
        let request = URLRequest(url: URL(string: "https://plex.tv/api/v2/pins?strong=true")!, method: "POST", headers: headers)
        let object = try jsonObject(try await http.data(for: request).0)
        guard let id = JSONRead.int(object["id"]), let code = object["code"] as? String else { throw MuurError.invalidData("Plex PIN") }
        return PlexPIN(id: id, code: code)
    }

    /// Page where the user approves the PIN.
    public func authURL(for pin: PlexPIN) -> URL {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "clientID", value: clientIdentifier), URLQueryItem(name: "code", value: pin.code),
                                 URLQueryItem(name: "context[device][product]", value: MediaServerIdentity.product)]
        return URL(string: "https://app.plex.tv/auth#?" + (components.percentEncodedQuery ?? ""))!
    }

    /// Polls plex.tv until the PIN is approved (or `timeout` elapses).
    public func waitForToken(_ pin: PlexPIN, timeout: TimeInterval = 300) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            let request = URLRequest(url: URL(string: "https://plex.tv/api/v2/pins/\(pin.id)")!, method: "GET", headers: headers)
            let object = try jsonObject(try await http.data(for: request).0)
            if let token = object["authToken"] as? String, !token.isEmpty { return token }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw MuurError.authenticationFailed("The Plex sign-in timed out")
    }

    /// Servers available to the account.
    public func servers(accountToken: String) async throws -> [PlexServer] {
        var request = URLRequest(url: URL(string: "https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1")!, method: "GET", headers: headers)
        request.setValue(accountToken, forHTTPHeaderField: "X-Plex-Token")
        let data = try await http.data(for: request).0
        let resources = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        return resources.compactMap { resource in
            guard (resource["provides"] as? String ?? "").contains("server"), let name = resource["name"] as? String,
                  let identifier = resource["clientIdentifier"] as? String else { return nil }
            let connections: [PlexServer.Connection] = JSONRead.objects(resource["connections"]).compactMap { connection in
                guard let text = connection["uri"] as? String, let uri = URL(string: text) else { return nil }
                return PlexServer.Connection(uri: uri, isLocal: JSONRead.bool(connection["local"]), isRelay: JSONRead.bool(connection["relay"]))
            }
            return PlexServer(name: name, clientIdentifier: identifier, accessToken: resource["accessToken"] as? String ?? accountToken,
                              connections: connections, isOwned: JSONRead.bool(resource["owned"]))
        }
    }

    /// First reachable connection: local, then remote, then relay.
    public func bestConnection(for server: PlexServer) async -> URL? {
        let ordered = server.connections.sorted { lhs, rhs in
            func rank(_ c: PlexServer.Connection) -> Int { c.isRelay ? 2 : (c.isLocal ? 0 : 1) }
            return rank(lhs) < rank(rhs)
        }
        for connection in ordered {
            var request = URLRequest(url: connection.uri.appendingPathComponent("identity"), method: "GET", headers: headers)
            request.setValue(server.accessToken, forHTTPHeaderField: "X-Plex-Token")
            request.timeoutInterval = 5
            if (try? await http.data(for: request)) != nil { return connection.uri }
        }
        return nil
    }

    /// A source configuration for a server (store `server.accessToken` as `SourceSecrets.token`).
    public func makeConfig(for server: PlexServer, url: URL) -> SourceConfig {
        SourceConfig(kind: .plex, name: server.name, host: url.absoluteString, options: [
            SourceConfig.OptionKey.serverID: server.clientIdentifier,
            SourceConfig.OptionKey.plexClientIdentifier: clientIdentifier,
            SourceConfig.OptionKey.useTLS: url.scheme == "https" ? "true" : "false",
        ])
    }
}

/// Plex Media Server music libraries. `config.host` = server URL; `SourceSecrets.token` = server access token.
/// URIs: `plex://<sourceId>/<ratingKey>`.
public final class PlexSource: MusicSource {
    public let config: SourceConfig
    public var capabilities: SourceCapabilities { [.browse, .search, .directURL, .library] }
    private let baseURL: URL
    private let token: String
    private let http: HTTPClient
    private let partKeys = LockedValue<[String: String]>([:])
    private let clientIdentifier: String

    public init(config: SourceConfig, secrets: SourceSecrets) throws {
        self.config = config
        baseURL = try MediaServerIdentity.baseURL(config)
        guard let token = secrets.token, !token.isEmpty else { throw MuurError.authenticationFailed("Sign in to Plex first") }
        self.token = token
        clientIdentifier = config.option(SourceConfig.OptionKey.plexClientIdentifier) ?? MediaServerIdentity.deviceID
        http = HTTPClient(allowInsecureTLS: true)
    }

    private func url(_ path: String, _ query: [String: String] = [:]) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let cleanPath = path.hasPrefix("/") ? path : "/" + path
        if let questionMark = cleanPath.firstIndex(of: "?") {
            components.path = String(cleanPath[..<questionMark])
            components.percentEncodedQuery = String(cleanPath[cleanPath.index(after: questionMark)...])
        } else {
            components.path = cleanPath
        }
        var items = components.queryItems ?? []
        items += query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "X-Plex-Token", value: token))
        components.queryItems = items
        return components.url!
    }

    private func container(_ path: String, _ query: [String: String] = [:]) async throws -> [String: Any] {
        let request = URLRequest(url: url(path, query), method: "GET", headers: [
            "Accept": "application/json", "X-Plex-Client-Identifier": clientIdentifier, "X-Plex-Product": MediaServerIdentity.product,
        ])
        let object = try jsonObject(try await http.data(for: request).0)
        return object["MediaContainer"] as? [String: Any] ?? [:]
    }

    private func uri(_ key: String) -> String {
        SourceURI(scheme: "plex", authority: config.id.uuidString, path: key).description
    }

    private func artwork(_ thumb: String?) -> URL? {
        guard let thumb, !thumb.isEmpty else { return nil }
        return url("/photo/:/transcode", ["width": "600", "height": "600", "minSize": "1", "url": thumb])
    }

    func track(_ metadata: [String: Any]) -> Track? {
        guard let key = JSONRead.string(metadata, "ratingKey") else { return nil }
        let media = JSONRead.objects(metadata["Media"]).first ?? [:]
        let part = JSONRead.objects(media["Part"]).first ?? [:]
        if let partKey = part["key"] as? String { partKeys.mutate { $0[key] = partKey } }
        let file = (part["file"] as? String).map(PathUtils.lastComponent)
        let containerName = JSONRead.string(media, "container") ?? JSONRead.string(part, "container") ?? ""
        let title = JSONRead.string(metadata, "title") ?? "Untitled"
        let albumArtist = JSONRead.string(metadata, "grandparentTitle") ?? ""
        let stream = JSONRead.objects(part["Stream"]).first { JSONRead.int($0["streamType"]) == 2 } ?? [:]
        var track = Track(sourceURI: uri(key), sourceID: config.id.uuidString, folderPath: config.name,
                          fileName: file ?? title + (containerName.isEmpty ? "" : "." + containerName), title: title,
                          artist: JSONRead.string(metadata, "originalTitle") ?? albumArtist, album: JSONRead.string(metadata, "parentTitle") ?? "",
                          albumArtist: albumArtist, year: JSONRead.int(metadata["parentYear"]) ?? JSONRead.int(metadata["year"]),
                          trackNumber: JSONRead.int(metadata["index"]), discNumber: JSONRead.int(metadata["parentIndex"]),
                          rating: (JSONRead.int(metadata["userRating"]) ?? 0) / 2, playCount: JSONRead.int(metadata["viewCount"]) ?? 0,
                          dateAdded: JSONRead.double(metadata["addedAt"]).map { Date(timeIntervalSince1970: $0) } ?? Date(),
                          duration: (JSONRead.double(metadata["duration"]) ?? JSONRead.double(media["duration"]) ?? 0) / 1000,
                          bitrate: JSONRead.int(media["bitrate"]) ?? 0, sampleRate: JSONRead.double(stream["samplingRate"]) ?? 0,
                          bitDepth: JSONRead.int(stream["bitDepth"]) ?? 0, channels: JSONRead.int(media["audioChannels"]) ?? 0,
                          fileSize: JSONRead.int64(part["size"]) ?? 0)
        track.codec = MetadataReader.normalizeCodec(JSONRead.string(media, "audioCodec")?.uppercased(), fileExtension: containerName)
        return track
    }

    private func item(_ metadata: [String: Any]) -> SourceItem? {
        guard let key = JSONRead.string(metadata, "ratingKey") else { return nil }
        let type = JSONRead.string(metadata, "type") ?? ""
        let thumb = JSONRead.string(metadata, "thumb") ?? JSONRead.string(metadata, "parentThumb")
        switch type {
        case "track":
            guard let track = self.track(metadata) else { return nil }
            return SourceItem(uri: track.sourceURI, name: track.title, kind: .audio, path: key, size: track.fileSize, track: track,
                              artworkURL: artwork(thumb), subtitle: track.artist)
        case "album":
            let year = JSONRead.int(metadata["year"]).map { " (\($0))" } ?? ""
            return SourceItem(uri: uri("album:" + key), name: (JSONRead.string(metadata, "title") ?? "") + year, kind: .folder, path: "album:" + key,
                              artworkURL: artwork(thumb), childCount: JSONRead.int(metadata["leafCount"]),
                              subtitle: JSONRead.string(metadata, "parentTitle"))
        case "artist":
            return SourceItem(uri: uri("artist:" + key), name: JSONRead.string(metadata, "title") ?? "", kind: .folder, path: "artist:" + key,
                              artworkURL: artwork(thumb), subtitle: "Artist")
        case "playlist":
            return SourceItem(uri: uri("playlist:" + key), name: JSONRead.string(metadata, "title") ?? "", kind: .folder,
                              path: "playlist:" + key, artworkURL: artwork(JSONRead.string(metadata, "composite") ?? thumb),
                              childCount: JSONRead.int(metadata["leafCount"]))
        default:
            return nil
        }
    }

    private func virtualFolder(_ path: String, _ name: String) -> SourceItem {
        SourceItem(uri: uri(path), name: name, kind: .folder, path: path)
    }

    private func musicSections() async throws -> [[String: Any]] {
        JSONRead.objects(try await container("/library/sections")["Directory"]).filter { JSONRead.string($0, "type") == "artist" }
    }

    public func connect() async throws {
        _ = try await container("/identity")
    }

    public func list(_ parent: SourceItem?) async throws -> [SourceItem] {
        guard let path = parent?.path, !path.isEmpty else {
            var items = try await musicSections().compactMap { section -> SourceItem? in
                guard let key = JSONRead.string(section, "key") else { return nil }
                return virtualFolder("section:" + key, JSONRead.string(section, "title") ?? "Music")
            }
            items.append(virtualFolder("playlists", "Playlists"))
            return items
        }
        let parts = path.split(separator: ":", maxSplits: 1).map(String.init)
        let id = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "section":
            return [virtualFolder("sectionAlbums:" + id, "Albums"), virtualFolder("sectionArtists:" + id, "Artists")]
        case "sectionAlbums":
            return JSONRead.objects(try await container("/library/sections/\(id)/all", ["type": "9", "sort": "titleSort"])["Metadata"]).compactMap(item)
        case "sectionArtists":
            return JSONRead.objects(try await container("/library/sections/\(id)/all", ["type": "8", "sort": "titleSort"])["Metadata"]).compactMap(item)
        case "artist", "album":
            return JSONRead.objects(try await container("/library/metadata/\(id)/children")["Metadata"]).compactMap(item)
        case "playlists":
            return JSONRead.objects(try await container("/playlists", ["playlistType": "audio"])["Metadata"]).compactMap(item)
        case "playlist":
            return JSONRead.objects(try await container("/playlists/\(id)/items")["Metadata"]).compactMap(item)
        default:
            return []
        }
    }

    public func search(_ text: String) async throws -> [SourceItem] {
        let hubs = JSONRead.objects(try await container("/hubs/search", ["query": text, "limit": "40"])["Hub"])
        return hubs.filter { ["artist", "album", "track"].contains(JSONRead.string($0, "type") ?? "") }
            .flatMap { JSONRead.objects($0["Metadata"]) }
            .compactMap(item)
    }

    public func libraryTracks(progress: @escaping @Sendable (Int, Int) -> Void) async throws -> [Track]? {
        var tracks: [Track] = []
        for section in try await musicSections() {
            guard let key = JSONRead.string(section, "key") else { continue }
            var start = 0
            while true {
                try Task.checkCancellation()
                let page = try await container("/library/sections/\(key)/all", ["type": "10", "X-Plex-Container-Start": String(start),
                                                                                 "X-Plex-Container-Size": "500"])
                let metadata = JSONRead.objects(page["Metadata"])
                tracks += metadata.compactMap(track)
                start += metadata.count
                let total = JSONRead.int(page["totalSize"]) ?? 0
                progress(tracks.count, total)
                if metadata.isEmpty || (total > 0 && start >= total) || (total == 0 && metadata.count < 500) { break }
            }
        }
        return tracks
    }

    private func partKey(for uri: String) async throws -> String {
        guard let parsed = SourceURI.parse(uri), parsed.scheme == "plex" else { throw MuurError.invalidData("Not a Plex URI") }
        if let cached = partKeys.get()[parsed.path] { return cached }
        let metadata = JSONRead.objects(try await container("/library/metadata/\(parsed.path)")["Metadata"])
        _ = metadata.first.flatMap(track)
        guard let key = partKeys.get()[parsed.path] else { throw MuurError.notFound(uri) }
        return key
    }

    public func streamURL(for uri: String) async throws -> RemoteResource? {
        RemoteResource(url: url(try await partKey(for: uri)))
    }

    public func download(uri: String, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let resource = url(try await partKey(for: uri), ["download": "1"])
        try await http.download(URLRequest(url: resource), to: destination, progress: progress)
    }
}
