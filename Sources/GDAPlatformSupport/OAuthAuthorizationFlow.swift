import Foundation
#if os(Windows)
import WinSDK
#endif
import GeminiDesignAgentCore

public protocol OAuthCallbackListening: Sendable {
    var redirectURI: String { get }
    func waitForCallback() async throws -> URL
    func close()
}

public protocol OAuthBrowserOpening: Sendable {
    func open(_ url: URL) throws
}

public struct SystemOAuthBrowser: OAuthBrowserOpening {
    public init() {}

    public func open(_ url: URL) throws {
        #if os(Windows)
        let result = url.absoluteString.withCString(encodedAs: UTF16.self) { wideURL in
            ShellExecuteW(nil, nil, wideURL, nil, nil, SW_SHOWNORMAL)
        }
        guard Int(bitPattern: result) > 32 else {
            throw OAuthError.authorizationDenied("Windows rejected the browser launch")
        }
        #elseif os(Linux)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xdg-open")
        process.arguments = [url.absoluteString]
        try process.run()
        #else
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        try process.run()
        #endif
    }
}

public struct OAuthAuthorizationFlow: Sendable {
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date
    private let randomBytes: @Sendable (Int) -> [UInt8]

    public init(
        transport: HTTPTransport = URLSessionHTTPTransport(),
        now: @escaping @Sendable () -> Date = Date.init,
        randomBytes: @escaping @Sendable (Int) -> [UInt8] = OAuthCrypto.secureRandomBytes
    ) {
        self.transport = transport
        self.now = now
        self.randomBytes = randomBytes
    }

    public func signIn(
        configuration: OAuthClientConfiguration,
        listener: any OAuthCallbackListening,
        browser: any OAuthBrowserOpening = SystemOAuthBrowser(),
        backend: OAuthBackend = .codeAssist
    ) async throws -> OAuthTokenSet {
        let verifier = OAuthCrypto.base64URL(randomBytes(64))
        let state = OAuthCrypto.base64URL(randomBytes(32))
        let challenge = OAuthCrypto.base64URL(OAuthCrypto.sha256(Data(verifier.utf8)))
        let useCodeAssistScopes = backend == .codeAssist
        let scopes = useCodeAssistScopes ? OAuthEndpoints.codeAssistScopes : OAuthEndpoints.scopes
        let authorizationURL: URL
        if useCodeAssistScopes {
            authorizationURL = try GeminiCLIOAuthClient.authorizationURL(
                redirectURI: listener.redirectURI,
                verifierChallenge: challenge,
                state: state,
                scopes: scopes
            )
        } else {
            authorizationURL = try makeAuthorizationURL(
                configuration: configuration,
                redirectURI: listener.redirectURI,
                verifierChallenge: challenge,
                state: state,
                scopes: scopes
            )
        }
        do {
            try browser.open(authorizationURL)
        } catch {
            listener.close()
            throw OAuthError.authorizationDenied("Could not open the system browser")
        }
        defer { listener.close() }
        let callback = try await withTaskCancellationHandler(
            operation: { try await listener.waitForCallback() },
            onCancel: { listener.close() }
        )
        let expectedPath = URLComponents(string: listener.redirectURI)?.path ?? "/oauth/callback"
        let code = try validate(callback: callback, expectedState: state, redirectURI: listener.redirectURI, expectedPath: expectedPath)
        return try await exchangeCode(
            code: code,
            verifier: verifier,
            redirectURI: listener.redirectURI,
            configuration: useCodeAssistScopes ? GeminiCLIOAuthClient.configuration : configuration,
            backend: backend
        )
    }

    public func makeAuthorizationURL(
        configuration: OAuthClientConfiguration,
        redirectURI: String,
        verifierChallenge: String,
        state: String,
        scopes: [String] = OAuthEndpoints.scopes
    ) throws -> URL {
        var components = URLComponents(url: OAuthEndpoints.authorization, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "code_challenge", value: verifierChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "include_granted_scopes", value: "true"),
            URLQueryItem(name: "prompt", value: "consent select_account"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state)
        ]
        guard let url = components?.url else { throw OAuthError.invalidClientConfiguration("Could not create authorization URL") }
        return url
    }

    public func validate(callback: URL, expectedState: String, redirectURI: String, expectedPath: String = "/oauth/callback") throws -> String {
        guard let expected = URLComponents(string: redirectURI),
              callback.scheme == "http",
              callback.host == "127.0.0.1",
              callback.path == expectedPath,
              callback.port == expected.port else {
            throw OAuthError.callbackRejected
        }
        let values = callback.queryItemsByName
        if let errors = values["error"], errors.count == 1 {
            guard values["code"] == nil, values["state"]?.count == 1 else {
                throw OAuthError.callbackRejected
            }
            throw OAuthError.authorizationDenied(errors[0])
        }
        guard values["error"] == nil else { throw OAuthError.callbackRejected }
        guard values["code"]?.count == 1, let code = values["code"]?.first, !code.isEmpty,
              values["state"]?.count == 1, let state = values["state"]?.first,
              OAuthCrypto.constantTimeEqual(state, expectedState) else {
            throw OAuthError.callbackRejected
        }
        return code
    }

    private func exchangeCode(
        code: String,
        verifier: String,
        redirectURI: String,
        configuration: OAuthClientConfiguration,
        backend: OAuthBackend = .codeAssist
    ) async throws -> OAuthTokenSet {
        let request = GeminiHTTPRequest(
            url: OAuthEndpoints.token,
            method: "POST",
            headers: ["Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"],
            body: OAuthForm.body([
                "client_id": configuration.clientID,
                "client_secret": configuration.clientSecret,
                "code": code,
                "code_verifier": verifier,
                "grant_type": "authorization_code",
                "redirect_uri": redirectURI
            ]),
            timeoutSeconds: 30
        )
        let response = try await transport.execute(request)
        guard (200...299).contains(response.statusCode) else {
            throw OAuthError.tokenExchangeFailed("HTTP \(response.statusCode)")
        }
        struct TokenResponse: Decodable {
            let accessToken: String
            let refreshToken: String?
            let expiresIn: Int
            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
                case expiresIn = "expires_in"
            }
        }
        let tokenResponse: TokenResponse
        do {
            tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: response.body)
        } catch {
            throw OAuthError.tokenExchangeFailed("Token response was invalid")
        }
        guard !tokenResponse.accessToken.isEmpty, tokenResponse.expiresIn > 0 else {
            throw OAuthError.tokenExchangeFailed("Token response was incomplete")
        }
        let identity = try await fetchIdentity(accessToken: tokenResponse.accessToken, backend: backend)
        return OAuthTokenSet(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken ?? "",
            expiresAt: now().addingTimeInterval(TimeInterval(tokenResponse.expiresIn)),
            subject: identity.subject,
            email: identity.email
        )
    }

    private func fetchIdentity(accessToken: String, backend: OAuthBackend = .codeAssist) async throws -> (subject: String, email: String) {
        let response = try await transport.execute(GeminiHTTPRequest(
            url: OAuthEndpoints.userInfo,
            method: "GET",
            headers: ["Authorization": "Bearer \(accessToken)"],
            body: Data(),
            timeoutSeconds: 30
        ))
        guard (200...299).contains(response.statusCode) else {
            throw OAuthError.tokenExchangeFailed("Could not retrieve Google account identity")
        }
        struct Identity: Decodable {
            let sub: String?
            let id: String?
            let email: String?
        }
        let identity = try JSONDecoder().decode(Identity.self, from: response.body)
        let subject = identity.sub ?? identity.id ?? ""
        guard !subject.isEmpty, let email = identity.email, !email.isEmpty else {
            throw OAuthError.tokenExchangeFailed("Google account identity was incomplete")
        }
        return (subject, email)
    }
}

private enum OAuthForm {
    static func body(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let value = fields.sorted { $0.key < $1.key }.map { key, value in
            let encode: (String) -> String = { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
            return "\(encode(key))=\(encode(value))"
        }.joined(separator: "&")
        return Data(value.utf8)
    }
}

extension URL {
    var queryItemsByName: [String: [String]] {
        var result: [String: [String]] = [:]
        for item in URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            guard let value = item.value else { continue }
            result[item.name, default: []].append(value)
        }
        return result
    }

    var hasWellFormedOAuthCallbackParameters: Bool {
        let values = queryItemsByName
        guard values["state"]?.count == 1 else { return false }
        let codes = values["code"] ?? []
        let errors = values["error"] ?? []
        if codes.count == 1, !codes[0].isEmpty, errors.isEmpty { return true }
        return codes.isEmpty && errors.count == 1
    }
}

public enum OAuthCrypto {
    public static func secureRandomBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }

    public static func base64URL(_ bytes: [UInt8]) -> String {
        base64URL(Data(bytes))
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = left.count ^ right.count
        for index in 0..<max(left.count, right.count) {
            difference |= Int((index < left.count ? left[index] : 0) ^ (index < right.count ? right[index] : 0))
        }
        return difference == 0
    }

    public static func sha256(_ data: Data) -> Data {
        var message = Array(data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        message += withUnsafeBytes(of: bitLength.bigEndian, Array.init)

        var hash: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
        ]
        let constants: [UInt32] = [
            0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
        ]
        for offset in stride(from: 0, to: message.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 64)
            for index in 0..<16 {
                let base = offset + index * 4
                words[index] = (UInt32(message[base]) << 24) | (UInt32(message[base + 1]) << 16) | (UInt32(message[base + 2]) << 8) | UInt32(message[base + 3])
            }
            for index in 16..<64 {
                let s0 = words[index - 15].rotatedRight(7) ^ words[index - 15].rotatedRight(18) ^ (words[index - 15] >> 3)
                let s1 = words[index - 2].rotatedRight(17) ^ words[index - 2].rotatedRight(19) ^ (words[index - 2] >> 10)
                words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
            }
            var a = hash[0], b = hash[1], c = hash[2], d = hash[3], e = hash[4], f = hash[5], g = hash[6], h = hash[7]
            for index in 0..<64 {
                let s1 = e.rotatedRight(6) ^ e.rotatedRight(11) ^ e.rotatedRight(25)
                let choice = (e & f) ^ (~e & g)
                let temp1 = h &+ s1 &+ choice &+ constants[index] &+ words[index]
                let s0 = a.rotatedRight(2) ^ a.rotatedRight(13) ^ a.rotatedRight(22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ majority
                h = g; g = f; f = e; e = d &+ temp1; d = c; c = b; b = a; a = temp1 &+ temp2
            }
            hash[0] &+= a; hash[1] &+= b; hash[2] &+= c; hash[3] &+= d
            hash[4] &+= e; hash[5] &+= f; hash[6] &+= g; hash[7] &+= h
        }
        return Data(hash.flatMap { value in withUnsafeBytes(of: value.bigEndian, Array.init) })
    }
}

private extension UInt32 {
    func rotatedRight(_ amount: UInt32) -> UInt32 { (self >> amount) | (self << (32 - amount)) }
}
