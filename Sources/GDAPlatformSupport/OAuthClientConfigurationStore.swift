import Foundation

public protocol OAuthClientConfigurationStoring: Sendable {
    var persistenceDescription: String { get }
    func load() throws -> OAuthClientConfiguration?
    func save(_ configuration: OAuthClientConfiguration) throws
}

public struct PlatformOAuthClientConfigurationStore: OAuthClientConfigurationStoring, Sendable {
    private let secureStore: SecureCredentialStore

    public init() {
        secureStore = SecureCredentialStore(namespace: "oauth", slot: "client-v1")
    }

    public var persistenceDescription: String { secureStore.persistenceDescription }

    public func load() throws -> OAuthClientConfiguration? {
        guard let encoded = try secureStore.load(),
              let data = encoded.data(using: .utf8) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(OAuthClientConfiguration.self, from: data)
        } catch {
            throw OAuthError.credentialStoreUnavailable("Stored OAuth client configuration is invalid")
        }
    }

    public func save(_ configuration: OAuthClientConfiguration) throws {
        let data = try JSONEncoder().encode(configuration)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw APIKeyStoreError.invalidEncoding
        }
        try secureStore.save(encoded)
    }
}

public struct OAuthClientConfigurationResolver: Sendable {
    private let store: any OAuthClientConfigurationStoring

    public init(store: any OAuthClientConfigurationStoring = PlatformOAuthClientConfigurationStore()) {
        self.store = store
    }

    public var persistenceDescription: String { store.persistenceDescription }

    public func configured() throws -> OAuthClientConfiguration? {
        try store.load()
    }

    @discardableResult
    public func importConfiguration(from url: URL) throws -> OAuthClientConfiguration {
        let configuration = try OAuthClientConfiguration.load(from: url)
        try store.save(configuration)
        return configuration
    }

    public func remember(_ configuration: OAuthClientConfiguration) throws {
        try store.save(configuration)
    }
}
