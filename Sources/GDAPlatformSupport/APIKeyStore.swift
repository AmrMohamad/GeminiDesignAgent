import Foundation
import GeminiDesignAgentCore

public protocol APIKeyStore: APIKeyReadableStore {
    init(slot: String)
    var persistenceDescription: String { get }
    func save(_ key: String) throws
    func delete() throws
}

public enum APIKeyStoreError: Error, LocalizedError, Equatable {
    case emptyKey
    case invalidEncoding
    case unavailable(String)
    case commandFailed(String)
    case credentialStore(String)

    public var errorDescription: String? {
        switch self {
        case .emptyKey: "API key cannot be empty"
        case .invalidEncoding: "API key could not be encoded"
        case .unavailable(let message): message
        case .commandFailed(let message): message
        case .credentialStore(let message): message
        }
    }
}

public extension APIKeyStore {
    func validated(_ key: String) throws -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw APIKeyStoreError.emptyKey
        }
        return trimmed
    }
}

public typealias KeychainAPIKeyStore = PlatformAPIKeyStore
