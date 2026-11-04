import Foundation
import GRDB

/// All source types MuurMusic can browse.
public enum SourceKind: String, Codable, CaseIterable, Sendable {
    case local, iCloud, smb, webdav, ftp, sftp, upnp, s3, dropbox, googleDrive, oneDrive, box, pCloud
    case subsonic, jellyfin, emby, plex

    public var displayName: String {
        switch self {
        case .local: return "Local Folder"
        case .iCloud: return "iCloud Drive"
        case .smb: return "SMB (Windows Share / NAS)"
        case .webdav: return "WebDAV"
        case .ftp: return "FTP / FTPS"
        case .sftp: return "SFTP"
        case .upnp: return "DLNA / UPnP"
        case .s3: return "S3 Compatible"
        case .dropbox: return "Dropbox"
        case .googleDrive: return "Google Drive"
        case .oneDrive: return "OneDrive"
        case .box: return "Box"
        case .pCloud: return "pCloud"
        case .subsonic: return "Subsonic / Navidrome"
        case .jellyfin: return "Jellyfin"
        case .emby: return "Emby"
        case .plex: return "Plex"
        }
    }

    /// SF Symbol suggestion for the UI.
    public var systemImage: String {
        switch self {
        case .local: return "folder"
        case .iCloud: return "icloud"
        case .smb, .webdav, .ftp, .sftp: return "externaldrive.connected.to.line.below"
        case .upnp: return "tv.and.mediabox"
        case .s3: return "shippingbox"
        case .dropbox, .googleDrive, .oneDrive, .box, .pCloud: return "cloud"
        case .subsonic, .jellyfin, .emby, .plex: return "server.rack"
        }
    }

    public var usesOAuth: Bool {
        switch self {
        case .dropbox, .googleDrive, .oneDrive, .box, .pCloud: return true
        default: return false
        }
    }

    /// URI scheme used for tracks from this source (see SHARED_FORMATS "Source URIs").
    public var uriScheme: String {
        switch self {
        case .local, .iCloud: return "file"
        case .smb: return "smb"
        case .webdav: return "webdav"
        case .ftp: return "ftp"
        case .sftp: return "sftp"
        case .upnp: return "upnp"
        case .s3: return "s3"
        case .dropbox: return "dropbox"
        case .googleDrive: return "gdrive"
        case .oneDrive: return "onedrive"
        case .box: return "box"
        case .pCloud: return "pcloud"
        case .subsonic: return "subsonic"
        case .jellyfin, .emby: return "jellyfin"
        case .plex: return "plex"
        }
    }

    /// `true` when URIs are `scheme://<sourceId>/…` instead of `scheme://host/…`.
    public var uriUsesSourceID: Bool {
        switch self {
        case .local, .iCloud, .smb, .webdav, .ftp, .sftp: return false
        default: return true
        }
    }

    public var defaultPort: Int? {
        switch self {
        case .smb: return 445
        case .ftp: return 21
        case .sftp: return 22
        case .jellyfin: return 8096
        case .emby: return 8096
        case .plex: return 32400
        case .subsonic: return 4533
        default: return nil
        }
    }
}

/// Persisted configuration of a source. Secrets live in `CredentialStore`, never here.
public struct SourceConfig: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: SourceKind
    public var name: String
    /// Host name or IP (or full base URL for WebDAV / media servers / S3 endpoints).
    public var host: String
    public var port: Int?
    /// Root path inside the server / share (WebDAV base path, SFTP start folder, S3 bucket[/prefix]...).
    public var basePath: String
    /// User name, S3 access key id, Subsonic user...
    public var username: String
    /// Kind-specific options; see `SourceConfig.OptionKey`.
    public var options: [String: String]
    public var sortIndex: Int
    public var createdAt: Date

    public enum OptionKey {
        /// "true" to use TLS (WebDAV https, FTPS, media servers over https).
        public static let useTLS = "useTLS"
        /// FTP: "explicit" (AUTH TLS) or "implicit".
        public static let ftpTLSMode = "ftpTLSMode"
        /// "true" to accept self-signed certificates.
        public static let allowInsecureTLS = "allowInsecureTLS"
        /// SMB share name (empty = list shares at root).
        public static let smbShare = "smbShare"
        public static let smbDomain = "smbDomain"
        /// WebDAV preset raw value (`WebDAVPreset`).
        public static let webdavPreset = "webdavPreset"
        /// S3 options.
        public static let s3Region = "s3Region"
        public static let s3Endpoint = "s3Endpoint"
        public static let s3PathStyle = "s3PathStyle"
        public static let s3Provider = "s3Provider"
        /// UPnP device description URL.
        public static let upnpDescriptionURL = "upnpDescriptionURL"
        /// Jellyfin/Emby user id & server id, Plex server info.
        public static let userID = "userID"
        public static let serverID = "serverID"
        public static let serverURL = "serverURL"
        public static let plexClientIdentifier = "plexClientIdentifier"
        /// Account display name returned by OAuth providers.
        public static let accountName = "accountName"
        /// SFTP auth: "password" or "key".
        public static let sftpAuth = "sftpAuth"
        /// Subsonic: "true" to use legacy plain password auth instead of token+salt.
        public static let subsonicLegacyAuth = "subsonicLegacyAuth"
    }

    public init(id: UUID = UUID(), kind: SourceKind, name: String, host: String = "", port: Int? = nil,
                basePath: String = "", username: String = "", options: [String: String] = [:], sortIndex: Int = 0,
                createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.name = name
        self.host = host
        self.port = port
        self.basePath = basePath
        self.username = username
        self.options = options
        self.sortIndex = sortIndex
        self.createdAt = createdAt
    }

    public func option(_ key: String) -> String? {
        guard let value = options[key], !value.isEmpty else { return nil }
        return value
    }

    public func flag(_ key: String) -> Bool {
        options[key] == "true"
    }

    public var useTLS: Bool { flag(OptionKey.useTLS) }
    public var allowInsecureTLS: Bool { flag(OptionKey.allowInsecureTLS) }
}

extension SourceConfig: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "sources"
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy { .uppercaseString }
}

/// Parses and builds source URIs (SHARED_FORMATS "Source URIs").
public struct SourceURI: Hashable, Sendable, CustomStringConvertible {
    public var scheme: String
    /// Host for host-based schemes, source id string for id-based schemes, empty for file URIs.
    public var authority: String
    /// Decoded path / item id (always starts with "/" for path-based schemes; for id-based schemes the id
    /// without leading slash).
    public var path: String
    public var port: Int?

    public init(scheme: String, authority: String, path: String, port: Int? = nil) {
        self.scheme = scheme
        self.authority = authority
        self.path = path
        self.port = port
    }

    public static let idBasedSchemes: Set<String> = ["s3", "dropbox", "gdrive", "onedrive", "box", "pcloud", "subsonic", "jellyfin", "plex", "upnp"]

    public var sourceID: UUID? {
        SourceURI.idBasedSchemes.contains(scheme) ? UUID(uuidString: authority) : nil
    }

    public var isFile: Bool { scheme == "file" }
    public var isZip: Bool { scheme == "zip" }

    /// For `zip://<inner>!/<entry>` URIs: the inner URI and entry path.
    public var zipComponents: (inner: String, entry: String)? {
        guard isZip else { return nil }
        let body = description.dropFirst("zip://".count)
        guard let bang = body.range(of: "!/", options: .backwards) else { return nil }
        let inner = String(body[..<bang.lowerBound])
        let entry = String(body[bang.upperBound...]).removingPercentEncoding ?? String(body[bang.upperBound...])
        return (inner, entry)
    }

    private var rawZipBody: String?

    public var description: String {
        if let rawZipBody { return "zip://" + rawZipBody }
        switch scheme {
        case "file":
            return URL(fileURLWithPath: path).absoluteString
        default:
            let portText = port.map { ":\($0)" } ?? ""
            if SourceURI.idBasedSchemes.contains(scheme) {
                let encoded = scheme == "dropbox" || scheme == "s3"
                    ? PathUtils.percentEncodePath(path.hasPrefix("/") ? String(path.dropFirst()) : path)
                    : PathUtils.rfc3986Encode(path)
                return "\(scheme)://\(authority)/\(encoded)"
            }
            let p = path.hasPrefix("/") ? path : "/" + path
            return "\(scheme)://\(authority)\(portText)\(PathUtils.percentEncodePath(p))"
        }
    }

    public var url: URL? { URL(string: description) }

    /// Parses a URI string. Returns nil for malformed input.
    public static func parse(_ string: String) -> SourceURI? {
        if string.hasPrefix("zip://") {
            var uri = SourceURI(scheme: "zip", authority: "", path: "")
            uri.rawZipBody = String(string.dropFirst("zip://".count))
            return uri
        }
        guard let schemeEnd = string.range(of: "://") else { return nil }
        let scheme = String(string[..<schemeEnd.lowerBound]).lowercased()
        let rest = String(string[schemeEnd.upperBound...])
        if scheme == "file" {
            guard let url = URL(string: string) else { return nil }
            return SourceURI(scheme: "file", authority: "", path: url.path)
        }
        let slash = rest.firstIndex(of: "/") ?? rest.endIndex
        var authority = String(rest[..<slash])
        var pathPart = String(rest[slash...])
        var port: Int?
        if !idBasedSchemes.contains(scheme), let colon = authority.lastIndex(of: ":"), !authority.hasSuffix("]") {
            port = Int(authority[authority.index(after: colon)...])
            authority = String(authority[..<colon])
        }
        if pathPart.isEmpty { pathPart = "/" }
        let decoded = pathPart.removingPercentEncoding ?? pathPart
        if idBasedSchemes.contains(scheme) {
            let id = decoded.hasPrefix("/") ? String(decoded.dropFirst()) : decoded
            return SourceURI(scheme: scheme, authority: authority, path: id, port: nil)
        }
        return SourceURI(scheme: scheme, authority: authority, path: decoded, port: port)
    }

    public static func file(_ url: URL) -> String {
        url.standardizedFileURL.absoluteString
    }

    public static func zip(inner: String, entry: String) -> String {
        "zip://\(inner)!/\(PathUtils.percentEncodePath(entry))"
    }

    public static func == (lhs: SourceURI, rhs: SourceURI) -> Bool { lhs.description == rhs.description }
    public func hash(into hasher: inout Hasher) { hasher.combine(description) }
}
