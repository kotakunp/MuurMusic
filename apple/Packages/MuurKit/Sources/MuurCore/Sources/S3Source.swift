import Foundation

/// AWS Signature Version 4 signer for S3 and S3-compatible services.
public struct S3Signer: Sendable {
    public static let emptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    public static let unsignedPayload = "UNSIGNED-PAYLOAD"

    public var accessKey: String
    public var secretKey: String
    public var region: String
    public var service: String

    public init(accessKey: String, secretKey: String, region: String, service: String = "s3") {
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.region = region
        self.service = service
    }

    /// `yyyyMMdd'T'HHmmss'Z'` and `yyyyMMdd` in UTC.
    public static func timestamps(for date: Date) -> (amzDate: String, dateStamp: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let day = String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        return (day + String(format: "T%02d%02d%02dZ", c.hour ?? 0, c.minute ?? 0, c.second ?? 0), day)
    }

    /// URI-encodes a path for the canonical request (each segment encoded, `/` kept).
    public static func canonicalURI(_ path: String) -> String {
        let value = path.isEmpty ? "/" : path
        return value.split(separator: "/", omittingEmptySubsequences: false)
            .map { PathUtils.rfc3986Encode(String($0)) }
            .joined(separator: "/")
    }

    /// Canonical query string from decoded name/value pairs.
    public static func canonicalQuery(_ items: [(String, String)]) -> String {
        let encoded: [(String, String)] = items.map { item in
            (PathUtils.rfc3986Encode(item.0), PathUtils.rfc3986Encode(item.1))
        }
        let sorted = encoded.sorted { (a: (String, String), b: (String, String)) -> Bool in
            a.0 == b.0 ? a.1 < b.1 : a.0 < b.0
        }
        return sorted.map { pair in pair.0 + "=" + pair.1 }.joined(separator: "&")
    }

    static func queryItems(of url: URL) -> [(String, String)] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [] }
        return (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
    }

    static func hostHeader(_ url: URL) -> String {
        guard let host = url.host else { return "" }
        if let port = url.port, !((url.scheme == "https" && port == 443) || (url.scheme == "http" && port == 80)) {
            return "\(host):\(port)"
        }
        return host
    }

    /// The canonical request string.
    public static func canonicalRequest(method: String, path: String, query: [(String, String)], headers: [String: String],
                                        payloadHash: String) -> (request: String, signedHeaders: String) {
        var normalized: [String: String] = [:]
        for (key, value) in headers {
            let collapsed = value.trimmingCharacters(in: .whitespaces)
                .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
            normalized[key.lowercased()] = collapsed
        }
        let names = normalized.keys.sorted()
        let canonicalHeaders = names.map { "\($0):\(normalized[$0] ?? "")\n" }.joined()
        let signedHeaders = names.joined(separator: ";")
        let request = [method.uppercased(), canonicalURI(path), canonicalQuery(query), canonicalHeaders, signedHeaders, payloadHash]
            .joined(separator: "\n")
        return (request, signedHeaders)
    }

    public func credentialScope(dateStamp: String) -> String {
        "\(dateStamp)/\(region)/\(service)/aws4_request"
    }

    public func stringToSign(canonicalRequest: String, amzDate: String, dateStamp: String) -> String {
        ["AWS4-HMAC-SHA256", amzDate, credentialScope(dateStamp: dateStamp), Hashing.sha256Hex(canonicalRequest)].joined(separator: "\n")
    }

    public func signingKey(dateStamp: String) -> Data {
        let kDate = Hashing.hmacSHA256(key: Data(("AWS4" + secretKey).utf8), message: Data(dateStamp.utf8))
        let kRegion = Hashing.hmacSHA256(key: kDate, message: Data(region.utf8))
        let kService = Hashing.hmacSHA256(key: kRegion, message: Data(service.utf8))
        return Hashing.hmacSHA256(key: kService, message: Data("aws4_request".utf8))
    }

    public func signature(stringToSign: String, dateStamp: String) -> String {
        Hashing.hmacSHA256(key: signingKey(dateStamp: dateStamp), message: Data(stringToSign.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Headers to add to a request (Authorization, x-amz-date, x-amz-content-sha256, plus `extraHeaders`).
    public func authorizationHeaders(method: String, url: URL, extraHeaders: [String: String] = [:],
                                     payloadHash: String = S3Signer.emptyPayloadHash, date: Date = Date()) -> [String: String] {
        let (amzDate, dateStamp) = S3Signer.timestamps(for: date)
        var headers = extraHeaders
        headers["host"] = S3Signer.hostHeader(url)
        headers["x-amz-date"] = amzDate
        headers["x-amz-content-sha256"] = payloadHash
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? url.path
        let canonical = S3Signer.canonicalRequest(method: method, path: path, query: S3Signer.queryItems(of: url),
                                                  headers: headers, payloadHash: payloadHash)
        let toSign = stringToSign(canonicalRequest: canonical.request, amzDate: amzDate, dateStamp: dateStamp)
        let signatureValue = signature(stringToSign: toSign, dateStamp: dateStamp)
        headers["Authorization"] = "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(credentialScope(dateStamp: dateStamp)), "
            + "SignedHeaders=\(canonical.signedHeaders), Signature=\(signatureValue)"
        headers.removeValue(forKey: "host")
        return headers
    }

    /// Signs a request in place.
    public func sign(_ request: inout URLRequest, payloadHash: String = S3Signer.emptyPayloadHash, date: Date = Date()) {
        guard let url = request.url else { return }
        var extra: [String: String] = [:]
        for (key, value) in request.allHTTPHeaderFields ?? [:] where key.lowercased() == "range" || key.lowercased().hasPrefix("x-amz-") {
            extra[key.lowercased()] = value
        }
        let headers = authorizationHeaders(method: request.httpMethod ?? "GET", url: url, extraHeaders: extra, payloadHash: payloadHash, date: date)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    }

    /// A presigned URL (query string authentication), valid for `expires` seconds (max 7 days).
    public func presignedURL(method: String = "GET", url: URL, expires: Int = 3600, date: Date = Date()) -> URL {
        let (amzDate, dateStamp) = S3Signer.timestamps(for: date)
        var query = S3Signer.queryItems(of: url)
        query.append(("X-Amz-Algorithm", "AWS4-HMAC-SHA256"))
        query.append(("X-Amz-Credential", "\(accessKey)/\(credentialScope(dateStamp: dateStamp))"))
        query.append(("X-Amz-Date", amzDate))
        query.append(("X-Amz-Expires", String(min(max(expires, 1), 604_800))))
        query.append(("X-Amz-SignedHeaders", "host"))
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? url.path
        let canonical = S3Signer.canonicalRequest(method: method, path: path, query: query,
                                                  headers: ["host": S3Signer.hostHeader(url)], payloadHash: S3Signer.unsignedPayload)
        let toSign = stringToSign(canonicalRequest: canonical.request, amzDate: amzDate, dateStamp: dateStamp)
        let signatureValue = signature(stringToSign: toSign, dateStamp: dateStamp)
        let queryString = S3Signer.canonicalQuery(query) + "&X-Amz-Signature=" + signatureValue
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = queryString
        components.percentEncodedPath = S3Signer.canonicalURI(path)
        return components.url ?? url
    }
}

/// S3-compatible storage (AWS, Wasabi, Backblaze B2, MinIO, Cloudflare R2, DigitalOcean Spaces...).
///
/// `config.host`: endpoint ("s3.amazonaws.com", "https://s3.eu-central-1.wasabisys.com", "http://nas:9000");
/// `config.basePath`: "bucket" or "bucket/prefix" (empty = list buckets); `config.username`: access key id;
/// secret in `SourceSecrets.secretAccessKey`; options `s3Region` (default us-east-1) and `s3PathStyle`.
public final class S3Source: MusicSource {
    public let config: SourceConfig
    public var capabilities: SourceCapabilities { [.browse, .directURL, .upload, .delete, .search] }
    private let signer: S3Signer
    private let http: HTTPClient
    private let endpoint: URL
    private let pathStyle: Bool

    public init(config: SourceConfig, secrets: SourceSecrets) throws {
        self.config = config
        guard let secret = secrets.secretAccessKey, !config.username.isEmpty else {
            throw MuurError.notConfigured("S3 access key")
        }
        let region = config.option(SourceConfig.OptionKey.s3Region) ?? "us-east-1"
        signer = S3Signer(accessKey: config.username, secretKey: secret, region: region)
        var host = config.option(SourceConfig.OptionKey.s3Endpoint) ?? config.host
        if host.isEmpty { host = region == "us-east-1" ? "s3.amazonaws.com" : "s3.\(region).amazonaws.com" }
        if !host.contains("://") { host = "https://" + host }
        guard let url = URL(string: host) else { throw MuurError.invalidData("Invalid S3 endpoint") }
        endpoint = url
        let isAWS = url.host?.hasSuffix("amazonaws.com") == true
        pathStyle = config.option(SourceConfig.OptionKey.s3PathStyle).map { $0 == "true" } ?? !isAWS
        http = HTTPClient(allowInsecureTLS: config.allowInsecureTLS)
    }

    private var bucketAndPrefix: (bucket: String, prefix: String) {
        let trimmed = config.basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !trimmed.isEmpty else { return ("", "") }
        let parts = trimmed.split(separator: "/", maxSplits: 1).map(String.init)
        let prefix = parts.count > 1 ? parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" : ""
        return (parts[0], prefix)
    }

    /// URL for an object (or bucket when `key` is empty).
    func objectURL(bucket: String, key: String, query: [String: String] = [:]) -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        let encodedKey = key.split(separator: "/", omittingEmptySubsequences: false).map { PathUtils.rfc3986Encode(String($0)) }.joined(separator: "/")
        if bucket.isEmpty {
            components.percentEncodedPath = "/"
        } else if pathStyle {
            components.percentEncodedPath = "/" + PathUtils.rfc3986Encode(bucket) + (key.isEmpty ? "/" : "/" + encodedKey)
        } else {
            components.host = bucket + "." + (endpoint.host ?? "")
            components.percentEncodedPath = "/" + encodedKey
        }
        if !query.isEmpty {
            components.percentEncodedQuery = S3Signer.canonicalQuery(query.map { ($0.key, $0.value) })
        }
        return components.url!
    }

    private func signedData(_ url: URL, method: String = "GET", body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: url, method: method, body: body)
        let hash = body.map { Hashing.sha256Hex($0) } ?? S3Signer.emptyPayloadHash
        signer.sign(&request, payloadHash: hash)
        return try await http.data(for: request).0
    }

    public func connect() async throws {
        let location = bucketAndPrefix
        if location.bucket.isEmpty {
            _ = try await signedData(objectURL(bucket: "", key: ""))
        } else {
            _ = try await signedData(objectURL(bucket: location.bucket, key: "", query: ["list-type": "2", "max-keys": "1"]))
        }
    }

    func uri(bucket: String, key: String) -> String {
        SourceURI(scheme: "s3", authority: config.id.uuidString, path: bucket + "/" + key).description
    }

    /// Splits an `s3://` URI path into bucket and key.
    func parse(uri: String) throws -> (bucket: String, key: String) {
        guard let parsed = SourceURI.parse(uri), parsed.scheme == "s3" else { throw MuurError.invalidData("Not an S3 URI") }
        let parts = parsed.path.split(separator: "/", maxSplits: 1).map(String.init)
        guard let bucket = parts.first else { throw MuurError.invalidData("Missing bucket") }
        return (bucket, parts.count > 1 ? parts[1] : "")
    }

    public func list(_ container: SourceItem?) async throws -> [SourceItem] {
        let location = bucketAndPrefix
        var bucket = location.bucket
        var prefix = location.prefix
        if let container {
            let parsed = try parse(uri: container.uri)
            bucket = parsed.bucket
            prefix = parsed.key
        }
        if bucket.isEmpty { return try await listBuckets() }
        var items: [SourceItem] = []
        var token: String?
        repeat {
            var query = ["list-type": "2", "delimiter": "/", "prefix": prefix, "max-keys": "1000"]
            if let token { query["continuation-token"] = token }
            let data = try await signedData(objectURL(bucket: bucket, key: "", query: query))
            let root = try XMLTree.parse(data)
            for common in root.children("CommonPrefixes") {
                guard let value = common.childText("Prefix") else { continue }
                let name = PathUtils.lastComponent(String(value.dropLast()))
                items.append(SourceItem(uri: uri(bucket: bucket, key: value), name: name, kind: .folder, path: bucket + "/" + value))
            }
            for content in root.children("Contents") {
                guard let key = content.childText("Key"), key != prefix, !key.hasSuffix("/") else { continue }
                let name = PathUtils.lastComponent(key)
                items.append(SourceItem(uri: uri(bucket: bucket, key: key), name: name, kind: SourceItem.kind(forFileName: name),
                                        path: bucket + "/" + key, size: content.childText("Size").flatMap { Int64($0) },
                                        modified: content.childText("LastModified").flatMap(DateParsing.iso8601Date)))
            }
            token = root.childText("IsTruncated") == "true" ? root.childText("NextContinuationToken") : nil
        } while token != nil
        return items.sorted { ($0.kind == .folder ? 0 : 1, $0.name.lowercased()) < ($1.kind == .folder ? 0 : 1, $1.name.lowercased()) }
    }

    private func listBuckets() async throws -> [SourceItem] {
        let data = try await signedData(objectURL(bucket: "", key: ""))
        let root = try XMLTree.parse(data)
        return root.descendants("Bucket").compactMap { bucket in
            guard let name = bucket.childText("Name") else { return nil }
            return SourceItem(uri: uri(bucket: name, key: ""), name: name, kind: .folder, path: name + "/")
        }
    }

    public func streamURL(for uri: String) async throws -> RemoteResource? {
        let (bucket, key) = try parse(uri: uri)
        return RemoteResource(url: signer.presignedURL(url: objectURL(bucket: bucket, key: key), expires: 6 * 3600))
    }

    public func download(uri: String, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        guard let resource = try await streamURL(for: uri) else { throw MuurError.notFound(uri) }
        try await http.download(URLRequest(url: resource.url), to: destination, progress: progress)
    }

    public func search(_ text: String) async throws -> [SourceItem] {
        let location = bucketAndPrefix
        guard !location.bucket.isEmpty else { return [] }
        var results: [SourceItem] = []
        var token: String?
        let needle = text.lowercased()
        repeat {
            var query = ["list-type": "2", "prefix": location.prefix, "max-keys": "1000"]
            if let token { query["continuation-token"] = token }
            let data = try await signedData(objectURL(bucket: location.bucket, key: "", query: query))
            let root = try XMLTree.parse(data)
            for content in root.children("Contents") {
                guard let key = content.childText("Key"), key.lowercased().contains(needle), !key.hasSuffix("/") else { continue }
                let name = PathUtils.lastComponent(key)
                results.append(SourceItem(uri: uri(bucket: location.bucket, key: key), name: name, kind: SourceItem.kind(forFileName: name),
                                          path: location.bucket + "/" + key, size: content.childText("Size").flatMap { Int64($0) }))
            }
            token = root.childText("IsTruncated") == "true" ? root.childText("NextContinuationToken") : nil
        } while token != nil && results.count < 500
        return results
    }

    public func upload(from localURL: URL, to container: SourceItem?, fileName: String) async throws {
        let location = bucketAndPrefix
        let parsed = try container.map { try parse(uri: $0.uri) } ?? (location.bucket, location.prefix)
        let data = try Data(contentsOf: localURL)
        let url = objectURL(bucket: parsed.0, key: parsed.1 + fileName)
        var request = URLRequest(url: url, method: "PUT", headers: ["Content-Type": PathUtils.mimeType(forExtension: PathUtils.fileExtension(fileName))], body: data)
        signer.sign(&request, payloadHash: Hashing.sha256Hex(data))
        _ = try await http.data(for: request)
    }

    public func delete(_ item: SourceItem) async throws {
        let (bucket, key) = try parse(uri: item.uri)
        _ = try await signedData(objectURL(bucket: bucket, key: key), method: "DELETE")
    }
}
