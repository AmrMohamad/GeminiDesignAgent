import XCTest
@testable import GeminiDesignAgentCore

final class GeminiRequestTests: XCTestCase {
    func testGenerateContentRequestEncodesDocumentedTextAndImageShape() throws {
        let client = GeminiVisionClient(apiKey: "test-key")
        let body = client.makeGenerateContentRequest(
            systemInstruction: "Return JSON only.",
            parts: [
                .text("Describe this screen."),
                .imageData(data: "abc123", mimeType: "image/png")
            ],
            responseSchema: .object(["type": .string("object")])
        )

        let object = try encodeJSONObject(body)
        let contents = try XCTUnwrap(object["contents"] as? [[String: Any]])
        let firstContent = try XCTUnwrap(contents.first)
        let parts = try XCTUnwrap(firstContent["parts"] as? [[String: Any]])

        XCTAssertTrue((parts[0]["text"] as? String)?.contains("SYSTEM:") == true)
        XCTAssertEqual(parts[1]["text"] as? String, "Describe this screen.")

        let inlineData = try XCTUnwrap(parts[2]["inlineData"] as? [String: Any])
        XCTAssertEqual(inlineData["mimeType"] as? String, "image/png")
        XCTAssertEqual(inlineData["data"] as? String, "abc123")
    }

    func testGenerateContentRequestEncodesStructuredOutputUnderGenerationConfig() throws {
        let client = GeminiVisionClient(apiKey: "test-key")
        let body = client.makeGenerateContentRequest(
            systemInstruction: "Return JSON only.",
            parts: [.text("Analyze")],
            responseSchema: .object(["type": .string("object")])
        )

        let object = try encodeJSONObject(body)
        let generationConfig = try XCTUnwrap(object["generationConfig"] as? [String: Any])
        let responseFormat = try XCTUnwrap(generationConfig["responseFormat"] as? [[String: Any]])
        let firstFormat = try XCTUnwrap(responseFormat.first)
        let schema = try XCTUnwrap(firstFormat["schema"] as? [String: Any])

        XCTAssertEqual(firstFormat["type"] as? String, "text")
        XCTAssertEqual(firstFormat["mimeType"] as? String, "application/json")
        XCTAssertEqual(schema["type"] as? String, "OBJECT")
    }

    func testPreparedRequestUsesGenerateContentEndpointAndHeaderAPIKey() throws {
        let client = GeminiVisionClient(apiKey: "secret-key")
        let body = client.makeGenerateContentRequest(
            systemInstruction: "Return JSON only.",
            parts: [.text("Analyze")],
            responseSchema: .object(["type": .string("object")])
        )

        let prepared = try client.prepareRequest(model: "gemini-2.5-flash", body: body)

        XCTAssertEqual(prepared.url, "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")
        XCTAssertEqual(prepared.headers["x-goog-api-key"], "secret-key")
        XCTAssertEqual(prepared.headers["Content-Type"], "application/json")
        XCTAssertFalse(prepared.url.contains("secret-key"))
        XCTAssertEqual(prepared.url.components(separatedBy: "/models/").count - 1, 1)
    }

    func testPreparedRequestThrowsBeforeHTTPWhenAPIKeyMissing() throws {
        let client = GeminiVisionClient(apiKey: "")
        let body = client.makeGenerateContentRequest(
            systemInstruction: "Return JSON only.",
            parts: [.text("Analyze")],
            responseSchema: .object(["type": .string("object")])
        )

        XCTAssertThrowsError(try client.prepareRequest(model: "gemini-2.5-flash", body: body)) { error in
            guard case GeminiError.apiKeyMissing = error else {
                return XCTFail("Expected apiKeyMissing, got \(error)")
            }
        }
    }

    private func encodeJSONObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSON.compactEncoder.encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
