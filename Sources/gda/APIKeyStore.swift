import Foundation
import Security
import GeminiDesignAgentCore

protocol APIKeyStore: APIKeyReadableStore {
    func save(_ key: String) throws
    func delete() throws
}

struct KeychainAPIKeyStore: APIKeyStore {
    private let service = "com.geminidesignagent.gda"
    private let account = "gemini-api-key"

    func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw APIKeyStoreError.emptyKey
        }

        guard let data = trimmed.data(using: .utf8) else {
            throw APIKeyStoreError.invalidEncoding
        }

        var addQuery = baseQuery()
        addQuery[kSecValueData as String] = data

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }

        if addStatus == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                baseQuery() as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw APIKeyStoreError.keychain(status: updateStatus)
            }
            return
        }

        throw APIKeyStoreError.keychain(status: addStatus)
    }

    func load() throws -> String? {
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw APIKeyStoreError.keychain(status: status)
        }

        guard let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw APIKeyStoreError.invalidEncoding
        }

        return key
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw APIKeyStoreError.keychain(status: status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

enum APIKeyStoreError: Error, LocalizedError {
    case emptyKey
    case invalidEncoding
    case keychain(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptyKey:
            return "API key cannot be empty"
        case .invalidEncoding:
            return "API key could not be encoded"
        case .keychain(let status):
            return "Keychain error (\(status)): \(message(for: status))"
        }
    }

    private func message(for status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return message
        }
        return "Unknown Security.framework error"
    }
}
