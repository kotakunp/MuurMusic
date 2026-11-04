import Foundation
import CryptoKit

public enum Hashing {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(_ string: String) -> String {
        sha256Hex(Data(string.utf8))
    }

    public static func hmacSHA256(key: Data, message: Data) -> Data {
        let code = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key))
        return Data(code)
    }

    public static func md5Hex(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        if status != errSecSuccess {
            for i in 0..<count { bytes[i] = UInt8.random(in: 0...255) }
        }
        return Data(bytes)
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func randomToken(length: Int = 16) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }
}

/// A JSON value that preserves arbitrary content (used to keep unknown DSP node parameters).
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .number(let value): return value
        case .bool(let value): return value ? 1 : 0
        case .string(let value): return Double(value)
        default: return nil
        }
    }

    public var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .number(let value): return value == value.rounded() ? String(Int(value)) : String(value)
        case .bool(let value): return value ? "true" : "false"
        default: return nil
        }
    }
}

public enum PathUtils {
    /// Audio file extensions recognized by the library scanner and source browsers.
    public static let audioExtensions: Set<String> = [
        "flac", "alac", "m4a", "m4b", "m4p", "aac", "adts", "mp4", "m4v", "mov", "mp3", "mp2", "mp1", "mpga",
        "wav", "wave", "aif", "aiff", "aifc", "caf", "dsf", "dff", "dsd", "ape", "wv", "tta", "ogg", "oga", "opus",
        "spx", "mpc", "mp+", "mpp", "shn", "ac3", "eac3", "ec3", "mka", "mkv", "mpeg", "mpg", "mod", "xm", "it", "s3m",
        "mtm", "669", "amf", "w64", "rf64", "snd", "au", "3gp", "3g2", "amr",
    ]
    public static let playlistExtensions: Set<String> = ["m3u", "m3u8", "cue", "pls", "muursmart.json"]
    public static let archiveExtensions: Set<String> = ["zip"]
    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "bmp", "webp", "heic"]
    public static let lyricsExtensions: Set<String> = ["lrc", "txt"]

    public static func isAudio(_ name: String) -> Bool { audioExtensions.contains(fileExtension(name)) }
    public static func isPlaylist(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasSuffix(".muursmart.json") { return true }
        return ["m3u", "m3u8", "cue", "pls"].contains(fileExtension(name))
    }
    public static func isArchive(_ name: String) -> Bool { archiveExtensions.contains(fileExtension(name)) }

    public static func fileExtension(_ name: String) -> String {
        (name as NSString).pathExtension.lowercased()
    }

    public static func lastComponent(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        if let index = trimmed.lastIndex(of: "/") {
            return String(trimmed[trimmed.index(after: index)...])
        }
        return trimmed
    }

    public static func parent(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        guard let index = trimmed.lastIndex(of: "/") else { return "" }
        let parent = String(trimmed[..<index])
        return parent.isEmpty ? "/" : parent
    }

    public static func join(_ base: String, _ component: String) -> String {
        if base.isEmpty { return component }
        if base.hasSuffix("/") { return base + component }
        return base + "/" + component
    }

    /// Removes characters that are invalid in file names on Apple file systems and FAT/exFAT drives.
    public static func sanitizeFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>\0")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return "untitled" }
        return String(cleaned.prefix(200))
    }

    /// Title derived from a file name: strips the extension, leading track numbers and underscores.
    public static func titleFromFileName(_ name: String) -> String {
        var base = (name as NSString).deletingPathExtension.replacingOccurrences(of: "_", with: " ")
        if let range = base.range(of: #"^\s*\d{1,3}\s*[-.\s]\s*"#, options: .regularExpression), range.upperBound < base.endIndex {
            base = String(base[range.upperBound...])
        }
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? name : trimmed
    }

    /// Percent-encodes a path for use in a URL, keeping `/`.
    public static func percentEncodePath(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#[]@!$&'()*+,;=")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }

    /// Strict RFC 3986 unreserved-only encoding (S3, OAuth).
    public static func rfc3986Encode(_ string: String, keepSlash: Bool = false) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        if keepSlash { allowed.insert(charactersIn: "/") }
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    public static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "mp3": return "audio/mpeg"
        case "flac": return "audio/flac"
        case "m4a", "m4b", "alac", "aac": return "audio/mp4"
        case "mp4", "m4v": return "video/mp4"
        case "wav", "wave": return "audio/wav"
        case "aif", "aiff", "aifc": return "audio/aiff"
        case "ogg", "oga": return "audio/ogg"
        case "opus": return "audio/opus"
        case "dsf": return "audio/x-dsf"
        case "dff": return "audio/x-dff"
        case "ape": return "audio/x-ape"
        case "wv": return "audio/x-wavpack"
        case "mpc": return "audio/x-musepack"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "html": return "text/html; charset=utf-8"
        case "json": return "application/json"
        case "txt", "lrc", "cue", "m3u": return "text/plain; charset=utf-8"
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "zip": return "application/zip"
        default: return "application/octet-stream"
        }
    }
}

public enum DateParsing {
    private static let rfc1123: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    private static let iso8601 = ISO8601DateFormatter()
    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let lock = NSLock()

    public static func rfc1123Date(_ string: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return rfc1123.date(from: string)
    }

    public static func rfc1123String(_ date: Date) -> String {
        lock.lock(); defer { lock.unlock() }
        return rfc1123.string(from: date)
    }

    public static func iso8601Date(_ string: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        if let date = iso8601Fractional.date(from: string) { return date }
        if let date = iso8601.date(from: string) { return date }
        // Truncate 7-digit fractional seconds used by .NET servers (Jellyfin).
        if let dot = string.firstIndex(of: ".") {
            let suffixStart = string[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) ?? string.endIndex
            let trimmed = String(string[..<dot]) + String(string[suffixStart...])
            return iso8601.date(from: trimmed.hasSuffix("Z") || trimmed.contains("+") ? trimmed : trimmed + "Z")
        }
        return nil
    }

    /// Parses a year out of tag date strings like "2019", "2019-04-02" or "2019/04".
    public static func year(from string: String?) -> Int? {
        guard let string, string.count >= 4 else { return nil }
        let digits = string.prefix(4)
        guard let year = Int(digits), year > 0 else { return nil }
        return year
    }
}

/// Serializes requests so that at most one starts every `interval` seconds (MusicBrainz policy).
public actor RateLimiter {
    private let interval: TimeInterval
    private var nextAllowed = Date.distantPast

    public init(interval: TimeInterval) {
        self.interval = interval
    }

    public func wait() async {
        let now = Date()
        if nextAllowed > now {
            let delay = nextAllowed.timeIntervalSince(now)
            nextAllowed = nextAllowed.addingTimeInterval(interval)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        } else {
            nextAllowed = now.addingTimeInterval(interval)
        }
    }
}

/// A tiny lock-protected box for state shared with callbacks on arbitrary threads.
public final class LockedValue<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    public init(_ value: Value) {
        self.value = value
    }

    public func get() -> Value {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    public func set(_ newValue: Value) {
        lock.lock(); defer { lock.unlock() }
        value = newValue
    }

    @discardableResult
    public func mutate<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body(&value)
    }
}
