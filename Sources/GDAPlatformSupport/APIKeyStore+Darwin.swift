#if canImport(Security)
import Foundation
import Security

public struct PlatformAPIKeyStore: APIKeyStore {
    public let persistenceDescription = "macOS Keychain"

    private let service = "com.geminidesignagent.gda"
    private let account: String

    public init(slot: String = "primary") {
        account = slot == "primary" ? "gemini-api-key" : "gemini-api-key.(slot)"
    }

    public func save(_ key: String) throws {
        let trimmed = try validated(key)
        guard let data = trimmed.data(using: .utf8) else {
            throw APIKeyStoreError.invalidEncoding
        }

        var addQuery = baseQuery()
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess { return }
        if addStatus == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw APIKeyStoreError.credentialStore(keychainMessage(status: updateStatus))
            }
            return
        }
        throw APIKeyStoreError.credentialStore(keychainMessage(status: addStatus))
    }

    public func load() throws -> String? {
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw APIKeyStoreError.credentialStore(keychainMessage(status: status))
        }
        guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
            throw APIKeyStoreError.invalidEncoding
        }
        return key
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw APIKeyStoreError.credentialStore(keychainMessage(status: status))
        }
    }

    private func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private func keychainMessage(status: OSStatus) -> String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Security.framework error"
        return "Keychain error (\(status)): \(message)"
    }
}
#endif
