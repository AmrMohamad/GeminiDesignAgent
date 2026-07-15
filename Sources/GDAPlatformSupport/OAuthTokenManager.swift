import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GeminiDesignAgentCore

public actor OAuthTokenManager: GeminiRequestAuthorizer {
    private let profileID: String
    private let store: OAuthProfileStore
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date

    public init(
        profileID: String,
        store: OAuthProfileStore = OAuthProfileStore(),
        transport: HTTPTransport = URLSessionHTTPTransport(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.profileID = profileID
        self.store = store
        self.transport = transport
        self.now = now
    }

    public func headers(forceRefresh: Bool) async throws -> [String: String] {
        guard let secret = try store.loadSecret(profileID: profileID) else { throw OAuthError.profileNotFound }
        let tokens = try await validTokens(secret: secret, forceRefresh: forceRefresh)
        let profile = try? self.profile()
        var headers: [String: String] = [
            "Authorization": "Bearer \(tokens.accessToken)"
        ]
        if profile?.backend == .publicGeminiAPI, let quotaProject = profile?.quotaProjectID, !quotaProject.isEmpty {
            headers["x-goog-user-project"] = quotaProject
        }
        return headers
    }

    public func profile() throws -> OAuthProfile {
        let registry = try store.loadRegistry()
        guard let profile = registry.profiles.first(where: { $0.id == profileID }) else { throw OAuthError.profileNotFound }
        return profile
    }

    private func validTokens(secret: OAuthProfileSecret, forceRefresh: Bool) async throws -> OAuthTokenSet {
        if !forceRefresh && secret.tokens.expiresAt > now().addingTimeInterval(60) {
            return secret.tokens
        }
        var request = GeminiHTTPRequest(
            url: OAuthEndpoints.token,
            method: "POST",
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: formBody([
                "client_id": secret.configuration.clientID,
                "client_secret": secret.configuration.clientSecret,
                "refresh_token": secret.tokens.refreshToken,
                "grant_type": "refresh_token"
            ]),
            timeoutSeconds: 30
        )
        request.headers["Accept"] = "application/json"
        let response = try await transport.execute(request)
        guard (200...299).contains(response.statusCode) else {
            let body = redactedErrorBody(response.body)
            if body.localizedCaseInsensitiveContains("invalid_grant") {
                throw OAuthError.reauthenticationRequired
            }
            throw OAuthError.tokenExchangeFailed("HTTP \(response.statusCode)")
        }
        struct Response: Decodable {
            let accessToken: String
            let expiresIn: Int
            let refreshToken: String?
            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case expiresIn = "expires_in"
                case refreshToken = "refresh_token"
            }
        }
        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: response.body)
        } catch {
            throw OAuthError.tokenExchangeFailed("Token response was invalid")
        }
        guard !decoded.accessToken.isEmpty, decoded.expiresIn > 0 else {
            throw OAuthError.tokenExchangeFailed("Token response was incomplete")
        }
        var updated = secret
        updated.tokens.accessToken = decoded.accessToken
        updated.tokens.refreshToken = decoded.refreshToken?.isEmpty == false ? decoded.refreshToken! : secret.tokens.refreshToken
        updated.tokens.expiresAt = now().addingTimeInterval(TimeInterval(decoded.expiresIn))
        try store.saveSecret(updated, profileID: profileID)
        return updated.tokens
    }

    private func formBody(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let value = fields.sorted { $0.key < $1.key }.map { key, value in
            let encode: (String) -> String = { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
            return "\(encode(key))=\(encode(value))"
        }.joined(separator: "&")
        return Data(value.utf8)
    }

    private func redactedErrorBody(_ body: Data) -> String {
        String(decoding: body.prefix(512), as: UTF8.self)
            .replacingOccurrences(of: "access_token", with: "redacted")
            .replacingOccurrences(of: "refresh_token", with: "redacted")
    }
}
