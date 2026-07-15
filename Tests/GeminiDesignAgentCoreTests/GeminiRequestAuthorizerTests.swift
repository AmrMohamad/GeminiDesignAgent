import XCTest
@testable import GeminiDesignAgentCore

final class GeminiRequestAuthorizerTests: XCTestCase {
    func testOAuthAuthorizerAddsBearerProjectHeaderAndRetriesOne401WithForcedRefresh() async throws {
        let authorizer = RecordingAuthorizer()
        let transport = RecordingTransport([
            GeminiHTTPResponse(statusCode: 401, body: Data(#"{"error":{"message":"expired"}}"#.utf8)),
            GeminiHTTPResponse(statusCode: 200, body: Data(#"{"status":"completed","steps":[{"type":"model_output","content":[{"type":"text","text":"{}"}]}]}"#.utf8))
        ])
        let client = GeminiVisionClient(
            authorizer: authorizer,
            baseURL: URL(string: "https://example.test")!,
            transport: transport,
            timeoutSeconds: 1
        )

        _ = try await client.analyzeText(
            model: "gemini-primary",
            systemInstruction: "system",
            userPrompt: "user",
            responseSchema: .object([:])
        )

        let refreshFlags = await authorizer.refreshFlags()
        XCTAssertEqual(refreshFlags, [false, true])
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].headers["Authorization"], "Bearer cached")
        XCTAssertEqual(requests[1].headers["Authorization"], "Bearer refreshed")
        XCTAssertEqual(requests[0].headers["x-goog-user-project"], "project-id")
        XCTAssertNil(requests[0].headers["x-goog-api-key"])
    }

    private actor RecordingAuthorizer: GeminiRequestAuthorizer {
        private var flags: [Bool] = []

        func headers(forceRefresh: Bool) async throws -> [String: String] {
            flags.append(forceRefresh)
            return [
                "Authorization": forceRefresh ? "Bearer refreshed" : "Bearer cached",
                "x-goog-user-project": "project-id"
            ]
        }

        func refreshFlags() -> [Bool] { flags }
    }

    private actor RecordingTransport: HTTPTransport {
        private var responses: [GeminiHTTPResponse]
        private var captured: [GeminiHTTPRequest] = []

        init(_ responses: [GeminiHTTPResponse]) {
            self.responses = responses
        }

        func execute(_ request: GeminiHTTPRequest) async throws -> GeminiHTTPResponse {
            captured.append(request)
            guard !responses.isEmpty else { throw GeminiError.unexpectedResponse("missing response") }
            return responses.removeFirst()
        }

        func requests() -> [GeminiHTTPRequest] { captured }
    }
}
