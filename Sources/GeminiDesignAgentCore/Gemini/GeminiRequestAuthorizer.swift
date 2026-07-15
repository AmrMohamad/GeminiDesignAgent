import Foundation

/// Provides request headers without exposing credential material to callers.
/// OAuth implementations may refresh an access token when `forceRefresh` is true.
public protocol GeminiRequestAuthorizer: Sendable {
    func headers(forceRefresh: Bool) async throws -> [String: String]
}

public struct GeminiAPIKeyAuthorizer: GeminiRequestAuthorizer {
    private let apiKey: String

    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    public func headers(forceRefresh: Bool) async throws -> [String: String] {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GeminiError.apiKeyMissing
        }
        return ["x-goog-api-key": apiKey]
    }
}
