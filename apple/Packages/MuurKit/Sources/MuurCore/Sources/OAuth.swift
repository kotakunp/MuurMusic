import Foundation
import CryptoKit
import AuthenticationServices
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Cloud storage providers that use OAuth 2.0.
public enum OAuthProvider: String, CaseIterable, Sendable, Identifiable {
    case dropbox, googleDrive, oneDrive, box, pCloud

    public var id: String { rawValue }

    public init?(kind: SourceKind) {
        switch kind {
        case .dropbox: self = .dropbox
        case .googleDrive: self = .googleDrive
        case .oneDrive: self = .oneDrive
        case .box: self = .box
        case .pCloud: self = .pCloud
        default: return nil
        }
    }

    public var kind: SourceKind {
        switch self {
        case .dropbox: return .dropbox
        case .googleDrive: return .googleDrive
        case .oneDrive: return .oneDrive
        case .box: return .box
        case .pCloud: return .pCloud
        }
    }

    public var displayName: String { kind.displayName }

    /// Info.plist key holding the client id.
    public var clientIDKey: String {
        switch self {
        case .dropbox: return "MUUR_DROPBOX_CLIENT_ID"
        case .googleDrive: return "MUUR_GOOGLE_CLIENT_ID"
        case .oneDrive: return "MUUR_ONEDRIVE_CLIENT_ID"
        case .box: return "MUUR_BOX_CLIENT_ID"
        case .pCloud: return "MUUR_PCLOUD_CLIENT_ID"
        }
    }

    /// Info.plist key holding the client secret (Box requires one; the others are public PKCE clients).
    public var clientSecretKey: String? {
        self == .box ? "MUUR_BOX_CLIENT_SECRET" : nil
    }

    /// Last path component of the `muurmusic://oauth/<provider>` redirect URI.
    public var redirectName: String {
        switch self {
        case .dropbox: return "dropbox"
        case .googleDrive: return "gdrive"
        case .oneDrive: return "onedrive"
        case .box: return "box"
        case .pCloud: return "pcloud"
        }
    }

    var authorizeURL: URL {
        switch self {
        case .dropbox: return URL(string: "https://www.dropbox.com/oauth2/authorize")!
        case .googleDrive: return URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        case .oneDrive: return URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!
        case .box: return URL(string: "https://account.box.com/api/oauth2/authorize")!
        case .pCloud: return URL(string: "https://my.pcloud.com/oauth2/authorize")!
        }
    }

    var tokenURL: URL? {
        switch self {
        case .dropbox: return URL(string: "https://api.dropboxapi.com/oauth2/token")!
        case .googleDrive: return URL(string: "https://oauth2.googleapis.com/token")!
        case .oneDrive: return URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!
        case .box: return URL(string: "https://api.box.com/oauth2/token")!
        case .pCloud: return nil
        }
    }

    var scope: String? {
        switch self {
        case .googleDrive: return "https://www.googleapis.com/auth/drive"
        case .oneDrive: return "offline_access Files.ReadWrite.All User.Read"
        default: return nil
        }
    }

    /// pCloud's implicit grant needs no client secret; its tokens do not expire.
    var usesImplicitGrant: Bool { self == .pCloud }
    var usesPKCE: Bool { self == .dropbox || self == .googleDrive || self == .oneDrive }

    /// `true` when the client id (and secret) are present in the main bundle's Info.plist.
    public var isConfigured: Bool { (try? OAuthClientConfiguration.load(for: self)) != nil }
}

/// Client registration read from Info.plist.
public struct OAuthClientConfiguration: Sendable, Hashable {
    public var clientID: String
    public var clientSecret: String?
    public var redirectURI: String
    public var callbackScheme: String

    public init(clientID: String, clientSecret: String?, redirectURI: String, callbackScheme: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.redirectURI = redirectURI
        self.callbackScheme = callbackScheme
    }

    public static let urlScheme = "muurmusic"

    public static func load(for provider: OAuthProvider, bundle: Bundle = .main) throws -> OAuthClientConfiguration {
        func value(_ key: String) -> String? {
            guard let text = bundle.object(forInfoDictionaryKey: key) as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Unexpanded build settings such as "$(MUUR_DROPBOX_CLIENT_ID)" count as missing.
            return trimmed.isEmpty || trimmed.hasPrefix("$(") ? nil : trimmed
        }
        guard let clientID = value(provider.clientIDKey) else {
            throw MuurError.notConfigured("\(provider.displayName) sign-in (\(provider.clientIDKey) in Info.plist)")
        }
        var secret: String?
        if let secretKey = provider.clientSecretKey {
            guard let found = value(secretKey) else {
                throw MuurError.notConfigured("\(provider.displayName) sign-in (\(secretKey) in Info.plist)")
            }
            secret = found
        }
        let googleSuffix = ".apps.googleusercontent.com"
        if provider == .googleDrive && clientID.hasSuffix(googleSuffix) {
            // Google iOS/macOS clients only accept the reversed client id as redirect scheme.
            let scheme = "com.googleusercontent.apps." + String(clientID.dropLast(googleSuffix.count))
            return OAuthClientConfiguration(clientID: clientID, clientSecret: secret, redirectURI: scheme + ":/oauth2redirect/gdrive",
                                            callbackScheme: scheme)
        }
        return OAuthClientConfiguration(clientID: clientID, clientSecret: secret,
                                        redirectURI: "\(urlScheme)://oauth/\(provider.redirectName)", callbackScheme: urlScheme)
    }
}

/// Result of an interactive sign-in.
public struct OAuthSignInResult: Sendable {
    public var tokens: OAuthTokens
    public var accountName: String?
}

/// Runs OAuth 2.0 sign-in flows with `ASWebAuthenticationSession` (PKCE where supported) and refreshes tokens.
@MainActor
public final class OAuthManager {
    public static let shared = OAuthManager()

    /// Presentation hook: return the window that should present the sign-in sheet.
    /// When nil, the key window of the foreground scene is used.
    public var presentationAnchorProvider: (@MainActor () -> ASPresentationAnchor)?

    private var activeSession: ASWebAuthenticationSession?
    private var contextProvider: PresentationContextProvider?

    public init() {}

    /// `true` if `url` is an OAuth redirect for MuurMusic (the app should ignore it; the web session consumes it).
    public nonisolated static func isOAuthRedirect(_ url: URL) -> Bool {
        url.scheme == OAuthClientConfiguration.urlScheme && url.host == "oauth"
    }

    /// Interactive sign-in. Throws `MuurError.notConfigured` when the Info.plist keys are missing.
    public func signIn(_ provider: OAuthProvider, http: HTTPClient = .shared) async throws -> OAuthSignInResult {
        let client = try OAuthClientConfiguration.load(for: provider)
        let state = Hashing.randomToken(length: 24)
        let verifier = Hashing.base64URL(Hashing.randomBytes(48))
        let challenge = Hashing.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))

        var components = URLComponents(url: provider.authorizeURL, resolvingAgainstBaseURL: false)!
        var query: [String: String] = [
            "client_id": client.clientID,
            "redirect_uri": client.redirectURI,
            "response_type": provider.usesImplicitGrant ? "token" : "code",
            "state": state,
        ]
        if provider.usesPKCE {
            query["code_challenge"] = challenge
            query["code_challenge_method"] = "S256"
        }
        if let scope = provider.scope { query["scope"] = scope }
        switch provider {
        case .dropbox: query["token_access_type"] = "offline"
        case .googleDrive:
            query["access_type"] = "offline"
            query["prompt"] = "consent"
        case .oneDrive: query["response_mode"] = "query"
        default: break
        }
        components.setQuery(query)
        guard let authURL = components.url else { throw MuurError.invalidData("Invalid authorization URL") }

        let callback = try await present(authURL, callbackScheme: client.callbackScheme)
        let parameters = OAuthManager.parameters(of: callback)
        if let error = parameters["error"] {
            if error == "access_denied" { throw MuurError.cancelled }
            throw MuurError.authenticationFailed(parameters["error_description"] ?? error)
        }
        guard parameters["state"] == state else { throw MuurError.authenticationFailed("State mismatch") }

        var tokens: OAuthTokens
        if provider.usesImplicitGrant {
            guard let token = parameters["access_token"] else { throw MuurError.authenticationFailed("No access token returned") }
            var extra: [String: String] = [:]
            extra["hostname"] = parameters["hostname"] ?? (parameters["locationid"] == "2" ? "eapi.pcloud.com" : "api.pcloud.com")
            if let uid = parameters["uid"] { extra["uid"] = uid }
            tokens = OAuthTokens(accessToken: token, tokenType: "bearer", extra: extra)
        } else {
            guard let code = parameters["code"] else { throw MuurError.authenticationFailed("No authorization code returned") }
            var fields = ["grant_type": "authorization_code", "code": code, "client_id": client.clientID, "redirect_uri": client.redirectURI]
            if provider.usesPKCE { fields["code_verifier"] = verifier }
            if let secret = client.clientSecret { fields["client_secret"] = secret }
            if let scope = provider.scope, provider == .oneDrive { fields["scope"] = scope }
            tokens = try await OAuthManager.requestToken(provider, fields: fields, previous: nil, http: http)
        }
        let account = try? await OAuthManager.accountName(provider, tokens: tokens, http: http)
        return OAuthSignInResult(tokens: tokens, accountName: account)
    }

    private func present(_ url: URL, callbackScheme: String) async throws -> URL {
        let provider = PresentationContextProvider(anchor: presentationAnchorProvider)
        contextProvider = provider
        defer {
            activeSession = nil
            contextProvider = nil
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: MuurError.cancelled)
                } else {
                    continuation.resume(throwing: MuurError.authenticationFailed(error?.localizedDescription ?? "Sign-in failed"))
                }
            }
            session.presentationContextProvider = provider
            session.prefersEphemeralWebBrowserSession = false
            activeSession = session
            if !session.start() {
                activeSession = nil
                continuation.resume(throwing: MuurError.authenticationFailed("Could not start the sign-in session"))
            }
        }
    }

    /// Query and fragment parameters of a redirect URL.
    nonisolated static func parameters(of url: URL) -> [String: String] {
        var result: [String: String] = [:]
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        for item in components?.queryItems ?? [] { result[item.name] = item.value ?? "" }
        if let fragment = components?.fragment {
            var fragmentComponents = URLComponents()
            fragmentComponents.query = fragment
            for item in fragmentComponents.queryItems ?? [] { result[item.name] = item.value ?? "" }
        }
        return result
    }

    private struct TokenResponse: Decodable {
        var access_token: String
        var refresh_token: String?
        var expires_in: Double?
        var token_type: String?
    }

    nonisolated static func requestToken(_ provider: OAuthProvider, fields: [String: String], previous: OAuthTokens?,
                                         http: HTTPClient) async throws -> OAuthTokens {
        guard let tokenURL = provider.tokenURL else { throw MuurError.unsupported("Token refresh for \(provider.displayName)") }
        let request = URLRequest(url: tokenURL, method: "POST", headers: [
            "Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json",
        ], body: FormEncoding.encode(fields))
        let (data, response) = try await http.data(for: request, validate: false)
        guard (200..<300).contains(response.statusCode) else {
            let message = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw MuurError.authenticationFailed("\(provider.displayName) token request failed (HTTP \(response.statusCode)) \(message)")
        }
        let decoded: TokenResponse
        do {
            decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw MuurError.invalidData("Token response: \(error.localizedDescription)")
        }
        return OAuthTokens(accessToken: decoded.access_token,
                           refreshToken: decoded.refresh_token ?? previous?.refreshToken,
                           expiresAt: decoded.expires_in.map { Date().addingTimeInterval($0) },
                           tokenType: decoded.token_type, extra: previous?.extra ?? [:])
    }

    /// Exchanges a refresh token for a new access token.
    public nonisolated static func refresh(_ provider: OAuthProvider, tokens: OAuthTokens, http: HTTPClient = .shared) async throws -> OAuthTokens {
        guard !provider.usesImplicitGrant else { return tokens }
        guard let refreshToken = tokens.refreshToken else {
            throw MuurError.authenticationFailed("\(provider.displayName) session expired; sign in again")
        }
        let client = try OAuthClientConfiguration.load(for: provider)
        var fields = ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": client.clientID]
        if let secret = client.clientSecret { fields["client_secret"] = secret }
        if let scope = provider.scope, provider == .oneDrive { fields["scope"] = scope }
        return try await requestToken(provider, fields: fields, previous: tokens, http: http)
    }

    /// Display name / e-mail of the signed-in account.
    public nonisolated static func accountName(_ provider: OAuthProvider, tokens: OAuthTokens, http: HTTPClient = .shared) async throws -> String? {
        let auth = ["Authorization": "Bearer \(tokens.accessToken)"]
        let object: [String: Any]?
        switch provider {
        case .dropbox:
            let request = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/users/get_current_account")!, method: "POST",
                                     headers: auth.merging(["Content-Type": "application/json"]) { $1 }, body: Data("null".utf8))
            object = try JSONSerialization.jsonObject(with: try await http.data(for: request).0) as? [String: Any]
            return object?["email"] as? String ?? (object?["name"] as? [String: Any])?["display_name"] as? String
        case .googleDrive:
            let data = try await http.data(from: URL(string: "https://www.googleapis.com/drive/v3/about?fields=user")!, headers: auth)
            object = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["user"] as? [String: Any]
            return object?["emailAddress"] as? String ?? object?["displayName"] as? String
        case .oneDrive:
            let data = try await http.data(from: URL(string: "https://graph.microsoft.com/v1.0/me")!, headers: auth)
            object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return object?["userPrincipalName"] as? String ?? object?["displayName"] as? String
        case .box:
            let data = try await http.data(from: URL(string: "https://api.box.com/2.0/users/me")!, headers: auth)
            object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return object?["login"] as? String ?? object?["name"] as? String
        case .pCloud:
            let host = tokens.extra["hostname"] ?? "api.pcloud.com"
            let data = try await http.data(from: URL(string: "https://\(host)/userinfo")!, headers: auth)
            object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return object?["email"] as? String
        }
    }
}

/// Supplies the presentation anchor to `ASWebAuthenticationSession` (always called on the main thread).
@MainActor
final class PresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchor: (@MainActor () -> ASPresentationAnchor)?

    init(anchor: (@MainActor () -> ASPresentationAnchor)?) {
        self.anchor = anchor
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let anchor { return anchor() }
        return PresentationContextProvider.defaultAnchor()
    }

    static func defaultAnchor() -> ASPresentationAnchor {
        #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        if let key = windows.first(where: \.isKeyWindow) ?? windows.first { return key }
        if let scene = scenes.first { return UIWindow(windowScene: scene) }
        return UIWindow(frame: .zero)
        #elseif os(macOS)
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? NSWindow()
        #endif
    }
}

/// Holds the tokens of one cloud source, refreshing them when they expire and persisting updates.
public actor OAuthSession {
    public let provider: OAuthProvider
    public let sourceID: UUID
    private var tokens: OAuthTokens
    private let credentials: CredentialStore
    private let http: HTTPClient
    private var refreshTask: Task<OAuthTokens, Error>?

    public init(provider: OAuthProvider, sourceID: UUID, tokens: OAuthTokens, credentials: CredentialStore, http: HTTPClient = .shared) {
        self.provider = provider
        self.sourceID = sourceID
        self.tokens = tokens
        self.credentials = credentials
        self.http = http
    }

    public var currentTokens: OAuthTokens { tokens }

    /// A valid access token (refreshing first when it is about to expire).
    public func accessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh && !tokens.isExpired { return tokens.accessToken }
        if provider.usesImplicitGrant {
            if forceRefresh { throw MuurError.authenticationFailed("\(provider.displayName) session expired; sign in again") }
            return tokens.accessToken
        }
        if let refreshTask { return try await refreshTask.value.accessToken }
        let provider = self.provider
        let current = tokens
        let http = self.http
        let task = Task { try await OAuthManager.refresh(provider, tokens: current, http: http) }
        refreshTask = task
        defer { refreshTask = nil }
        let refreshed = try await task.value
        tokens = refreshed
        try? credentials.update(for: sourceID) { $0.oauth = refreshed }
        return refreshed.accessToken
    }

    public func extra(_ key: String) -> String? { tokens.extra[key] }
}

/// Bearer-authenticated HTTP helper used by cloud sources (retries once after refreshing on 401).
public struct CloudHTTP: Sendable {
    public let session: OAuthSession
    public let http: HTTPClient

    public init(session: OAuthSession, http: HTTPClient = .shared) {
        self.session = session
        self.http = http
    }

    public func data(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var authorized = request
        authorized.setValue("Bearer \(try await session.accessToken())", forHTTPHeaderField: "Authorization")
        do {
            return try await http.data(for: authorized)
        } catch MuurError.authenticationFailed(_) {
            authorized.setValue("Bearer \(try await session.accessToken(forceRefresh: true))", forHTTPHeaderField: "Authorization")
            return try await http.data(for: authorized)
        }
    }

    public func json(_ request: URLRequest) async throws -> [String: Any] {
        let (data, _) = try await self.data(request)
        if data.isEmpty { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MuurError.invalidData("Expected a JSON object")
        }
        return object
    }

    public func json(_ url: URL, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        var headers: [String: String] = ["Accept": "application/json"]
        var bodyData: Data?
        if let body {
            headers["Content-Type"] = "application/json"
            bodyData = try JSONSerialization.data(withJSONObject: body)
        }
        return try await json(URLRequest(url: url, method: method, headers: headers, body: bodyData))
    }

    public func download(_ request: URLRequest, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        var authorized = request
        authorized.setValue("Bearer \(try await session.accessToken())", forHTTPHeaderField: "Authorization")
        do {
            try await http.download(authorized, to: destination, progress: progress)
        } catch MuurError.authenticationFailed(_) {
            authorized.setValue("Bearer \(try await session.accessToken(forceRefresh: true))", forHTTPHeaderField: "Authorization")
            try await http.download(authorized, to: destination, progress: progress)
        }
    }

    public func bearerHeaders() async throws -> [String: String] {
        ["Authorization": "Bearer \(try await session.accessToken())"]
    }
}
