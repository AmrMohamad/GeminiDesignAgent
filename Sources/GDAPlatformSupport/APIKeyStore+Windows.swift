#if os(Windows)
import Foundation
import WinSDK

public struct PlatformAPIKeyStore: APIKeyStore {
    public let persistenceDescription = "Windows Credential Manager"
    private let target = "GeminiDesignAgent.GeminiAPIKey"
    private let account = "gemini-api-key"

    public init() {}

    public func save(_ key: String) throws {
        let trimmed = try validated(key)
        guard let data = trimmed.data(using: .utf8) else { throw APIKeyStoreError.invalidEncoding }
        try withWideCString(target) { targetPtr in
            try withWideCString(account) { accountPtr in
                try data.withUnsafeBytes { rawBuffer in
                    guard let blob = rawBuffer.bindMemory(to: BYTE.self).baseAddress else { throw APIKeyStoreError.invalidEncoding }
                    var credential = CREDENTIALW()
                    credential.Type = DWORD(CRED_TYPE_GENERIC)
                    credential.TargetName = UnsafeMutablePointer<WCHAR>(mutating: targetPtr)
                    credential.CredentialBlobSize = DWORD(rawBuffer.count)
                    credential.CredentialBlob = UnsafeMutablePointer<BYTE>(mutating: blob)
                    credential.Persist = DWORD(CRED_PERSIST_LOCAL_MACHINE)
                    credential.UserName = UnsafeMutablePointer<WCHAR>(mutating: accountPtr)
                    guard CredWriteW(&credential, 0) != 0 else {
                        throw APIKeyStoreError.credentialStore("Windows Credential Manager write failed with error \(GetLastError())")
                    }
                }
            }
        }
    }

    public func load() throws -> String? {
        var credentialPointer: PCREDENTIALW?
        let found = withWideCString(target) { CredReadW($0, DWORD(CRED_TYPE_GENERIC), 0, &credentialPointer) }
        guard found != 0 else {
            let error = GetLastError()
            if error == ERROR_NOT_FOUND { return nil }
            throw APIKeyStoreError.credentialStore("Windows Credential Manager read failed with error \(error)")
        }
        defer { if let credentialPointer { CredFree(credentialPointer) } }
        guard let credential = credentialPointer?.pointee, let blob = credential.CredentialBlob, credential.CredentialBlobSize > 0 else { return nil }
        let bytes = UnsafeRawBufferPointer(start: blob, count: Int(credential.CredentialBlobSize))
        guard let key = String(data: Data(bytes), encoding: .utf8) else { throw APIKeyStoreError.invalidEncoding }
        return key
    }

    public func delete() throws {
        let deleted = withWideCString(target) { CredDeleteW($0, DWORD(CRED_TYPE_GENERIC), 0) }
        guard deleted != 0 else {
            let error = GetLastError()
            if error == ERROR_NOT_FOUND { return }
            throw APIKeyStoreError.credentialStore("Windows Credential Manager delete failed with error \(error)")
        }
    }

    private func withWideCString<Result>(_ string: String, _ body: (UnsafePointer<WCHAR>) throws -> Result) rethrows -> Result {
        try string.withCString(encodedAs: UTF16.self) { ptr in
            try body(UnsafeRawPointer(ptr).assumingMemoryBound(to: WCHAR.self))
        }
    }
}
#endif
