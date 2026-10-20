import Foundation

/// OAuth tokens from Microsoft identity platform.
public struct TokenSet: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date

    public func isExpiring(at now: Date, margin: TimeInterval = 300) -> Bool {
        expiresAt.timeIntervalSince(now) < margin
    }
}

/// What the user must do to finish device-code sign-in.
public struct DeviceCodePrompt: Sendable, Equatable {
    public var userCode: String
    public var verificationURL: URL
    public var message: String
    public var expiresAt: Date
}

public enum AuthError: Error, Equatable, CustomStringConvertible {
    case notConfigured
    case notSignedIn
    case declined
    case expired
    case server(String)

    public var description: String {
        switch self {
        case .notConfigured: return "No OneDrive app client ID configured."
        case .notSignedIn: return "Not signed in to OneDrive."
        case .declined: return "Sign-in was declined."
        case .expired: return "Sign-in code expired. Try again."
        case .server(let m): return m
        }
    }
}

/// Configuration for the Azure app registration (public client, device-code flow enabled).
public struct AuthConfig: Sendable, Equatable {
    public var clientID: String
    /// "consumers" for personal OneDrive accounts; "common" also allows work/school accounts.
    public var tenant: String
    /// AppFolder keeps access limited to /Apps/Branch in the user's OneDrive.
    public var scopes: [String]

    public static let defaultScopes = ["Files.ReadWrite.AppFolder", "offline_access"]

    public init(clientID: String, tenant: String = "consumers", scopes: [String] = AuthConfig.defaultScopes) {
        self.clientID = clientID
        self.tenant = tenant
        self.scopes = scopes
    }

    var base: URL { URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/")! }
    var scope: String { scopes.joined(separator: " ") }
}

/// Supplies a valid Graph access token, refreshing as needed.
public protocol AccessTokenProvider: Sendable {
    func accessToken() async throws -> String
    /// Called after the server rejects a token; should return a fresh one.
    func refreshedAccessToken() async throws -> String
}

/// Device-code sign-in plus token refresh, with tokens persisted in the Keychain.
public actor AuthManager: AccessTokenProvider {
    public private(set) var config: AuthConfig?
    private var tokens: TokenSet?
    private let http: HTTPClient
    private let keychain: Keychain
    private let now: @Sendable () -> Date
    private static let account = "onedrive-tokens"

    public init(
        config: AuthConfig?,
        http: HTTPClient = URLSession.shared,
        keychain: Keychain = Keychain(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.http = http
        self.keychain = keychain
        self.now = now
        if let data = try? keychain.read(Self.account) {
            self.tokens = try? JSONDecoder().decode(TokenSet.self, from: data)
        }
    }

    public var isSignedIn: Bool { tokens != nil }

    public func setConfig(_ config: AuthConfig?) {
        if config?.clientID != self.config?.clientID {
            signOut()
        }
        self.config = config
    }

    public func signOut() {
        tokens = nil
        try? keychain.delete(Self.account)
    }

    /// Starts device-code sign-in. Call `completeDeviceCode` with the returned handle to wait for the user.
    public func startDeviceCode() async throws -> (prompt: DeviceCodePrompt, deviceCode: String, interval: TimeInterval) {
        guard let config else { throw AuthError.notConfigured }
        let req = URLRequest.form(config.base.appendingPathComponent("devicecode"), [
            "client_id": config.clientID,
            "scope": config.scope,
        ])
        let (data, resp) = try await http.send(req)
        struct Body: Decodable {
            let device_code: String
            let user_code: String
            let verification_uri: String
            let expires_in: Double
            let interval: Double?
            let message: String?
        }
        guard resp.statusCode == 200 else { throw Self.serverError(data) }
        let b = try JSONDecoder().decode(Body.self, from: data)
        let prompt = DeviceCodePrompt(
            userCode: b.user_code,
            verificationURL: URL(string: b.verification_uri) ?? URL(string: "https://microsoft.com/devicelogin")!,
            message: b.message ?? "Open \(b.verification_uri) and enter \(b.user_code)",
            expiresAt: now().addingTimeInterval(b.expires_in)
        )
        return (prompt, b.device_code, b.interval ?? 5)
    }

    /// Polls until the user finishes sign-in, declines, or the code expires.
    public func completeDeviceCode(_ deviceCode: String, interval: TimeInterval, expiresAt: Date) async throws {
        guard let config else { throw AuthError.notConfigured }
        var wait = interval
        while now() < expiresAt {
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            let req = URLRequest.form(config.base.appendingPathComponent("token"), [
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "client_id": config.clientID,
                "device_code": deviceCode,
            ])
            let (data, resp) = try await http.send(req)
            if resp.statusCode == 200 {
                try store(try decodeTokens(data))
                return
            }
            switch Self.errorCode(data) {
            case "authorization_pending": continue
            case "slow_down": wait += 5
            case "authorization_declined": throw AuthError.declined
            case "expired_token": throw AuthError.expired
            default: throw Self.serverError(data)
            }
        }
        throw AuthError.expired
    }

    public func accessToken() async throws -> String {
        guard let current = tokens else { throw AuthError.notSignedIn }
        if !current.isExpiring(at: now()) { return current.accessToken }
        return try await refresh().accessToken
    }

    public func refreshedAccessToken() async throws -> String {
        try await refresh().accessToken
    }

    /// Forces a refresh, e.g. after a 401.
    @discardableResult
    public func refresh() async throws -> TokenSet {
        guard let config else { throw AuthError.notConfigured }
        guard let refreshToken = tokens?.refreshToken else { throw AuthError.notSignedIn }
        let req = URLRequest.form(config.base.appendingPathComponent("token"), [
            "grant_type": "refresh_token",
            "client_id": config.clientID,
            "refresh_token": refreshToken,
            "scope": config.scope,
        ])
        let (data, resp) = try await http.send(req)
        guard resp.statusCode == 200 else {
            if Self.errorCode(data) == "invalid_grant" { signOut() }
            throw Self.serverError(data)
        }
        var fresh = try decodeTokens(data)
        if fresh.refreshToken == nil { fresh.refreshToken = refreshToken }
        try store(fresh)
        return fresh
    }

    private func store(_ t: TokenSet) throws {
        tokens = t
        try keychain.write(try JSONEncoder().encode(t), Self.account)
    }

    private func decodeTokens(_ data: Data) throws -> TokenSet {
        struct Body: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double
        }
        let b = try JSONDecoder().decode(Body.self, from: data)
        return TokenSet(accessToken: b.access_token, refreshToken: b.refresh_token,
                        expiresAt: now().addingTimeInterval(b.expires_in))
    }

    private static func errorCode(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
    }

    private static func serverError(_ data: Data) -> AuthError {
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let msg = (obj?["error_description"] as? String) ?? (obj?["error"] as? String) ?? "Sign-in failed."
        return .server(msg)
    }
}
