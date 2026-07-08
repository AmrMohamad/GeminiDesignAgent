import Foundation

public protocol APIKeyReadableStore {
    func load() throws -> String?
}

public enum APIKeyResolver {
    public static func resolve(
        apiKey: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        store: APIKeyReadableStore
    ) throws -> String {
        if let apiKey {
            return try validated(apiKey)
        }

        if let envKey = environment["GEMINI_API_KEY"] {
            return try validated(envKey)
        }

        if let storedKey = try store.load() {
            return try validated(storedKey)
        }

        throw GeminiError.apiKeyMissing
    }

    private static func validated(_ key: String) throws -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GeminiError.apiKeyMissing
        }
        return trimmed
    }
}
