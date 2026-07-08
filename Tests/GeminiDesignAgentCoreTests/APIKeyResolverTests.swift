import XCTest
@testable import GeminiDesignAgentCore

final class APIKeyResolverTests: XCTestCase {
    func testLoadsFromKeychainStoreWhenNoOverrideExists() throws {
        let key = try APIKeyResolver.resolve(
            apiKey: nil,
            environment: [:],
            store: FakeAPIKeyStore(key: "stored-key")
        )

        XCTAssertEqual(key, "stored-key")
    }

    func testFlagOverridesEnvironmentAndKeychainStore() throws {
        let key = try APIKeyResolver.resolve(
            apiKey: "flag-key",
            environment: ["GEMINI_API_KEY": "env-key"],
            store: FakeAPIKeyStore(key: "stored-key")
        )

        XCTAssertEqual(key, "flag-key")
    }

    func testEnvironmentOverridesKeychainStoreWhenFlagMissing() throws {
        let key = try APIKeyResolver.resolve(
            apiKey: nil,
            environment: ["GEMINI_API_KEY": "env-key"],
            store: FakeAPIKeyStore(key: "stored-key")
        )

        XCTAssertEqual(key, "env-key")
    }

    func testMissingAllSourcesThrowsAPIKeyMissing() {
        XCTAssertThrowsError(try APIKeyResolver.resolve(
            apiKey: nil,
            environment: [:],
            store: FakeAPIKeyStore(key: nil)
        )) { error in
            guard case GeminiError.apiKeyMissing = error else {
                return XCTFail("Expected apiKeyMissing, got \(error)")
            }
        }
    }

    func testWhitespaceOverrideThrowsAPIKeyMissing() {
        XCTAssertThrowsError(try APIKeyResolver.resolve(
            apiKey: "   ",
            environment: [:],
            store: FakeAPIKeyStore(key: "stored-key")
        )) { error in
            guard case GeminiError.apiKeyMissing = error else {
                return XCTFail("Expected apiKeyMissing, got \(error)")
            }
        }
    }

    private struct FakeAPIKeyStore: APIKeyReadableStore {
        let key: String?

        func load() throws -> String? {
            key
        }
    }
}
