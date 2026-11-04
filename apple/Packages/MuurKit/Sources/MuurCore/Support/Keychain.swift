import Foundation
import Security

/// Minimal Keychain wrapper for generic passwords.
public struct Keychain: Sendable {
    public let service: String
    public let accessGroup: String?

    public init(service: String, accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    public func set(_ data: Data, account: String) throws {
        var query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            for (key, value) in attributes { query[key] = value }
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw MuurError.io("Keychain write failed (\(status))")
        }
    }

    public func data(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    public func remove(account: String) {
        let query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)
    }

    public func setString(_ value: String, account: String) throws {
        try set(Data(value.utf8), account: account)
    }

    public func string(account: String) -> String? {
        data(account: account).flatMap { String(data: $0, encoding: .utf8) }
    }
}

/// OAuth tokens persisted for cloud sources.
public struct OAuthTokens: Codable, Hashable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var tokenType: String?
    /// Provider-specific extras (pCloud API host, account id...).
    public var extra: [String: String]

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil, tokenType: String? = nil, extra: [String: String] = [:]) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.tokenType = tokenType
        self.extra = extra
    }

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow < 60
    }
}

/// Secrets belonging to one configured source. Stored only in the Keychain.
public struct SourceSecrets: Codable, Hashable, Sendable {
    public var password: String?
    /// PEM / OpenSSH private key text for SFTP.
    public var privateKey: String?
    public var privateKeyPassphrase: String?
    /// S3 secret access key (the access key id lives in `SourceConfig.username`).
    public var secretAccessKey: String?
    /// API tokens (Plex token, Jellyfin access token, Subsonic API key...).
    public var token: String?
    public var oauth: OAuthTokens?

    public init(password: String? = nil, privateKey: String? = nil, privateKeyPassphrase: String? = nil,
                secretAccessKey: String? = nil, token: String? = nil, oauth: OAuthTokens? = nil) {
        self.password = password
        self.privateKey = privateKey
        self.privateKeyPassphrase = privateKeyPassphrase
        self.secretAccessKey = secretAccessKey
        self.token = token
        self.oauth = oauth
    }
}

/// Stores `SourceSecrets` per source id in the Keychain.
public final class CredentialStore: @unchecked Sendable {
    public static let defaultService = "app.muur.music.sources"
    private let keychain: Keychain
    private let cache = LockedValue<[UUID: SourceSecrets]>([:])

    public init(service: String = CredentialStore.defaultService, accessGroup: String? = nil) {
        self.keychain = Keychain(service: service, accessGroup: accessGroup)
    }

    public func secrets(for sourceID: UUID) -> SourceSecrets {
        if let cached = cache.get()[sourceID] { return cached }
        guard let data = keychain.data(account: sourceID.uuidString),
              let secrets = try? JSONDecoder().decode(SourceSecrets.self, from: data) else {
            return SourceSecrets()
        }
        cache.mutate { $0[sourceID] = secrets }
        return secrets
    }

    public func save(_ secrets: SourceSecrets, for sourceID: UUID) throws {
        let data = try JSONEncoder().encode(secrets)
        try keychain.set(data, account: sourceID.uuidString)
        cache.mutate { $0[sourceID] = secrets }
    }

    public func update(for sourceID: UUID, _ body: (inout SourceSecrets) -> Void) throws {
        var current = secrets(for: sourceID)
        body(&current)
        try save(current, for: sourceID)
    }

    public func remove(for sourceID: UUID) {
        keychain.remove(account: sourceID.uuidString)
        cache.mutate { $0[sourceID] = nil }
    }
}
