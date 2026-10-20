import XCTest
@testable import BranchCore

final class AuthTests: XCTestCase {
    var keychain: Keychain!

    override func setUp() {
        keychain = Keychain(service: "com.branch.tests.\(UUID().uuidString)")
    }

    override func tearDown() {
        try? keychain.delete("onedrive-tokens")
    }

    func testDeviceCodeFlowStoresTokens() async throws {
        let http = StubHTTP()
        http.responses = [
            (200, #"{"device_code":"DC","user_code":"ABCD-1234","verification_uri":"https://microsoft.com/devicelogin","expires_in":900,"interval":1}"#, [:]),
            (400, #"{"error":"authorization_pending"}"#, [:]),
            (200, #"{"access_token":"AT","refresh_token":"RT","expires_in":3600}"#, [:]),
        ]
        let auth = AuthManager(config: AuthConfig(clientID: "cid"), http: http, keychain: keychain)
        let start = try await auth.startDeviceCode()
        XCTAssertEqual(start.prompt.userCode, "ABCD-1234")
        try await auth.completeDeviceCode(start.deviceCode, interval: 0.01, expiresAt: Date().addingTimeInterval(60))

        let token = try await auth.accessToken()
        XCTAssertEqual(token, "AT")
        let signedIn = await auth.isSignedIn
        XCTAssertTrue(signedIn)

        let body = String(data: http.requests[0].httpBody!, encoding: .utf8)!
        XCTAssertTrue(body.contains("client_id=cid"))
        XCTAssertTrue(body.contains("Files.ReadWrite.AppFolder"))

        // A fresh manager reads tokens back from the Keychain.
        let reloaded = AuthManager(config: AuthConfig(clientID: "cid"), http: http, keychain: keychain)
        let again = try await reloaded.accessToken()
        XCTAssertEqual(again, "AT")
    }

    func testDeclined() async throws {
        let http = StubHTTP()
        http.responses = [(400, #"{"error":"authorization_declined"}"#, [:])]
        let auth = AuthManager(config: AuthConfig(clientID: "cid"), http: http, keychain: keychain)
        do {
            try await auth.completeDeviceCode("DC", interval: 0.01, expiresAt: Date().addingTimeInterval(60))
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? AuthError, .declined)
        }
    }

    func testRefreshWhenExpiring() async throws {
        let expired = TokenSet(accessToken: "OLD", refreshToken: "RT", expiresAt: Date().addingTimeInterval(10))
        try keychain.write(JSONEncoder().encode(expired), "onedrive-tokens")
        let http = StubHTTP()
        http.responses = [(200, #"{"access_token":"NEW","expires_in":3600}"#, [:])]
        let auth = AuthManager(config: AuthConfig(clientID: "cid"), http: http, keychain: keychain)

        let token = try await auth.accessToken()
        XCTAssertEqual(token, "NEW")
        let body = String(data: http.requests[0].httpBody!, encoding: .utf8)!
        XCTAssertTrue(body.contains("grant_type=refresh_token"))
        XCTAssertTrue(body.contains("refresh_token=RT"))

        // Refresh token is kept when the server doesn't rotate it.
        let stored = try JSONDecoder().decode(TokenSet.self, from: XCTUnwrap(keychain.read("onedrive-tokens")))
        XCTAssertEqual(stored.refreshToken, "RT")
    }

    func testInvalidGrantSignsOut() async throws {
        let t = TokenSet(accessToken: "OLD", refreshToken: "RT", expiresAt: .distantPast)
        try keychain.write(JSONEncoder().encode(t), "onedrive-tokens")
        let http = StubHTTP()
        http.responses = [(400, #"{"error":"invalid_grant","error_description":"expired"}"#, [:])]
        let auth = AuthManager(config: AuthConfig(clientID: "cid"), http: http, keychain: keychain)
        do {
            _ = try await auth.accessToken()
            XCTFail("expected throw")
        } catch {}
        let signedIn = await auth.isSignedIn
        XCTAssertFalse(signedIn)
        XCTAssertNil(try keychain.read("onedrive-tokens"))
    }

    func testNotConfigured() async {
        let auth = AuthManager(config: nil, http: StubHTTP(), keychain: keychain)
        do {
            _ = try await auth.startDeviceCode()
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? AuthError, .notConfigured)
        }
    }
}
