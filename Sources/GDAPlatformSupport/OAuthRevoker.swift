import Foundation
import GeminiDesignAgentCore

public struct OAuthRevoker: Sendable {
    private let transport: HTTPTransport

    public init(transport: HTTPTransport = URLSessionHTTPTransport()) {
        self.transport = transport
    }

    public func revoke(refreshToken: String) async throws {
        let trimmed = refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OAuthError.profileNotFound }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let response = try await transport.execute(GeminiHTTPRequest(
            url: OAuthEndpoints.revoke,
            method: "POST",
            headers: ["Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"],
            body: Data("token=\(encoded)".utf8),
            timeoutSeconds: 30
        ))
        guard (200...299).contains(response.statusCode) else {
            // Deliberately do not include the body: OAuth endpoint errors can
            // reflect request fields and must not enter CLI diagnostics.
            throw OAuthError.tokenExchangeFailed("Remote revocation failed (HTTP \(response.statusCode))")
        }
    }
}
