import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import GDAPlatformSupport
import GeminiDesignAgentCore

final class OAuthSecurityTests: XCTestCase {
    func testAuthenticationModesMapToDistinctOAuthBackends() {
        XCTAssertEqual(AuthenticationMode(backend: .codeAssist), .codeAssist)
        XCTAssertEqual(AuthenticationMode(backend: .publicGeminiAPI), .publicOAuth)
        XCTAssertEqual(AuthenticationMode.codeAssist.backend, .codeAssist)
        XCTAssertEqual(AuthenticationMode.publicOAuth.backend, .publicGeminiAPI)
        XCTAssertNil(AuthenticationMode.apiKey.backend)
    }

    func testCreditPolicyRequiresEligibilityBalanceAndConsent() {
        let model = "gemini-3-pro-preview"
        let enabled = [CodeAssist.CreditType.googleOneAI.rawValue]

        XCTAssertNil(CodeAssistCreditPolicy.enabledCreditTypes(policy: .never, model: model, balance: 100, consentGranted: true))
        XCTAssertNil(CodeAssistCreditPolicy.enabledCreditTypes(policy: .ask, model: model, balance: 100, consentGranted: false))
        XCTAssertEqual(CodeAssistCreditPolicy.enabledCreditTypes(policy: .ask, model: model, balance: 100, consentGranted: true), enabled)
        XCTAssertEqual(CodeAssistCreditPolicy.enabledCreditTypes(policy: .always, model: model, balance: 100, consentGranted: false), enabled)
        XCTAssertNil(CodeAssistCreditPolicy.enabledCreditTypes(policy: .always, model: model, balance: 49, consentGranted: false))
        XCTAssertNil(CodeAssistCreditPolicy.enabledCreditTypes(policy: .always, model: "gemini-2.5-flash", balance: 100, consentGranted: false))
    }

    func testPKCES256MatchesRFC7636Vector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let challenge = OAuthCrypto.base64URL(OAuthCrypto.sha256(Data(verifier.utf8)))
        XCTAssertEqual(challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testStateUses256BitsAndComparisonRejectsMismatch() {
        let state = OAuthCrypto.base64URL(OAuthCrypto.secureRandomBytes(32))
        XCTAssertGreaterThanOrEqual(state.count, 43)
        XCTAssertTrue(OAuthCrypto.constantTimeEqual(state, state))
        XCTAssertFalse(OAuthCrypto.constantTimeEqual(state, state + "x"))
    }

    func testOnlyInstalledDesktopClientsAndGoogleEndpointsAreAccepted() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let valid = directory.appendingPathComponent("desktop.json")
        try Data(#"{"installed":{"client_id":"12345-abc.apps.googleusercontent.com","client_secret":"secret","project_id":"valid-project"}}"#.utf8).write(to: valid)
        XCTAssertEqual(try OAuthClientConfiguration.load(from: valid).projectID, "valid-project")

        let googleLegacy = directory.appendingPathComponent("google-legacy.json")
        try Data(#"{"installed":{"client_id":"12345-abc.apps.googleusercontent.com","client_secret":"secret","project_id":"valid-project","auth_uri":"https://accounts.google.com/o/oauth2/auth","token_uri":"https://oauth2.googleapis.com/token"}}"#.utf8).write(to: googleLegacy)
        XCTAssertEqual(try OAuthClientConfiguration.load(from: googleLegacy).projectID, "valid-project")

        let malicious = directory.appendingPathComponent("malicious.json")
        try Data(#"{"installed":{"client_id":"12345-abc.apps.googleusercontent.com","client_secret":"secret","project_id":"valid-project","token_uri":"https://evil.example/token"}}"#.utf8).write(to: malicious)
        XCTAssertThrowsError(try OAuthClientConfiguration.load(from: malicious)) { error in
            XCTAssertFalse(error.localizedDescription.contains("secret"))
        }

        let lookalike = directory.appendingPathComponent("lookalike.json")
        try Data(#"{"installed":{"client_id":"12345-abc.apps.googleusercontent.com","client_secret":"secret","project_id":"valid-project","auth_uri":"https://accounts.google.com.evil.example/o/oauth2/v2/auth"}}"#.utf8).write(to: lookalike)
        XCTAssertThrowsError(try OAuthClientConfiguration.load(from: lookalike))

        let web = directory.appendingPathComponent("web.json")
        try Data(#"{"web":{"client_id":"12345-abc.apps.googleusercontent.com","client_secret":"secret","project_id":"valid-project"}}"#.utf8).write(to: web)
        XCTAssertThrowsError(try OAuthClientConfiguration.load(from: web))
    }

    func testImportedLegacyGoogleAuthURIStillUsesPinnedV2RuntimeEndpoint() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clientJSON = directory.appendingPathComponent("desktop.json")
        try Data(#"{"installed":{"client_id":"12345-abc.apps.googleusercontent.com","client_secret":"secret","project_id":"valid-project","auth_uri":"https://accounts.google.com/o/oauth2/auth"}}"#.utf8).write(to: clientJSON)

        let configuration = try OAuthClientConfiguration.load(from: clientJSON)
        let authorizationURL = try OAuthAuthorizationFlow().makeAuthorizationURL(
            configuration: configuration,
            redirectURI: "http://127.0.0.1:43123/oauth/callback",
            verifierChallenge: "challenge",
            state: "state"
        )

        XCTAssertEqual(authorizationURL.scheme, "https")
        XCTAssertEqual(authorizationURL.host, "accounts.google.com")
        XCTAssertEqual(authorizationURL.path, "/o/oauth2/v2/auth")
    }

    func testOAuthClientImportIsStoredOnceAndSubsequentLoginNeedsNoJSONPath() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clientJSON = directory.appendingPathComponent("desktop.json")
        try Data(#"{"installed":{"client_id":"12345-abc.apps.googleusercontent.com","client_secret":"secret","project_id":"valid-project"}}"#.utf8).write(to: clientJSON)
        let store = InMemoryOAuthClientStore()
        let resolver = OAuthClientConfigurationResolver(store: store)

        let imported = try resolver.importConfiguration(from: clientJSON)
        try FileManager.default.removeItem(at: clientJSON)

        XCTAssertEqual(try resolver.configured(), imported)
        XCTAssertEqual(store.saveCount, 1)
        XCTAssertEqual(store.persistenceDescription, "test secure credential store")
    }

    func testMaliciousOAuthClientImportIsNotPersisted() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clientJSON = directory.appendingPathComponent("desktop.json")
        try Data(#"{"installed":{"client_id":"12345-abc.apps.googleusercontent.com","client_secret":"secret","project_id":"valid-project","token_uri":"https://evil.example/token"}}"#.utf8).write(to: clientJSON)
        let store = InMemoryOAuthClientStore()

        XCTAssertThrowsError(try OAuthClientConfigurationResolver(store: store).importConfiguration(from: clientJSON))
        XCTAssertNil(store.configuration)
        XCTAssertEqual(store.saveCount, 0)
    }

    func testCallbackRequiresExactLoopbackPortPathAndSingleStateAndCode() throws {
        let flow = OAuthAuthorizationFlow()
        let redirect = "http://127.0.0.1:43123/oauth/callback"
        XCTAssertEqual(
            try flow.validate(
                callback: try XCTUnwrap(URL(string: "http://127.0.0.1:43123/oauth/callback?code=once&state=expected")),
                expectedState: "expected",
                redirectURI: redirect
            ),
            "once"
        )
        for callback in [
            "http://localhost:43123/oauth/callback?code=once&state=expected",
            "http://127.0.0.1:43124/oauth/callback?code=once&state=expected",
            "http://127.0.0.1:43123/wrong?code=once&state=expected",
            "http://127.0.0.1:43123/oauth/callback?code=once&code=twice&state=expected",
            "http://127.0.0.1:43123/oauth/callback?code=once&state=wrong",
            "http://127.0.0.1:43123/oauth/callback?state=expected"
        ] {
            XCTAssertThrowsError(try flow.validate(callback: try XCTUnwrap(URL(string: callback)), expectedState: "expected", redirectURI: redirect))
        }
    }

    func testLoopbackListenerAcceptsOneBoundedValidCallbackAndReturnsNoStoreResponse() async throws {
        let listener = try PlatformOAuthCallbackListener(timeoutSeconds: 5)
        let expected = try XCTUnwrap(URL(string: listener.redirectURI + "?code=once&state=state"))
        async let callback = listener.waitForCallback()
        let (_, response) = try await URLSession.shared.data(from: expected)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        let received = try await callback
        XCTAssertEqual(received, expected)
    }

    func testObservedUsageUsesPacificBucketsRetainsThirtyTwoDaysAndIsPrivate() async throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let profileID = "7b9ba83e-4416-4f98-bf6b-34f567c94139"
        let oldDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-01T12:00:00Z"))
        let oldLedger = OAuthUsageLedger(homeDirectory: home, now: { oldDate })
        try await oldLedger.recordAttempt(profileID: profileID, model: "gemini-primary")

        let currentDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-02-05T12:00:00Z"))
        let ledger = OAuthUsageLedger(homeDirectory: home, now: { currentDate })
        try await ledger.recordAttempt(profileID: profileID, model: "gemini-primary")
        try await ledger.recordSuccess(profileID: profileID, model: "gemini-primary", usage: RunTokenUsage(inputTokens: 3, outputTokens: 5, totalTokens: 8))
        let entries = try await ledger.observedUsage(profileID: profileID)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].attempts, 1)
        XCTAssertEqual(entries[0].successes, 1)
        XCTAssertEqual(entries[0].totalTokens, 8)
        #if !os(Windows)
        let attributes = try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(".geminidesignagent/usage-v1.json").path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions.map { $0 & 0o777 }, 0o600)
        #endif
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gda-oauth-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class InMemoryOAuthClientStore: OAuthClientConfigurationStoring, @unchecked Sendable {
    let persistenceDescription = "test secure credential store"
    var configuration: OAuthClientConfiguration?
    var saveCount = 0

    func load() throws -> OAuthClientConfiguration? { configuration }

    func save(_ configuration: OAuthClientConfiguration) throws {
        self.configuration = configuration
        saveCount += 1
    }
}
