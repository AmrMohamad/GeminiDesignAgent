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

/// Stores arbitrary small UTF-8 secret payloads in the platform credential store.
/// This deliberately has no file-system fallback: OAuth refresh tokens must never
/// be persisted in plaintext.
public struct SecureCredentialStore: Sendable {
    private let namespace: String
    private let slot: String

    public init(namespace: String, slot: String) {
        self.namespace = namespace
        self.slot = slot
    }

    public var persistenceDescription: String {
        PlatformAPIKeyStore(namespace: namespace, slot: slot).persistenceDescription
    }

    public func save(_ value: String) throws {
        try PlatformAPIKeyStore(namespace: namespace, slot: slot).save(value)
    }

    public func load() throws -> String? {
        try PlatformAPIKeyStore(namespace: namespace, slot: slot).load()
    }

    public func delete() throws {
        try PlatformAPIKeyStore(namespace: namespace, slot: slot).delete()
    }
}
