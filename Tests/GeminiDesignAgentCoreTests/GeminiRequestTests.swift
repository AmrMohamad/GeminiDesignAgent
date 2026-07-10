import Foundation
import XCTest
@testable import GeminiDesignAgentCore

final class GeminiRequestTests: XCTestCase {
    func testPreparedRequestMatchesInteractionsV1Contract() throws {
        let client = GeminiVisionClient(apiKey: "secret-key")
        let body = client.makeInteractionRequest(
            model: GDAContract.defaultModel,
            systemInstruction: "Return JSON only.",
            input: [
                .text("Describe this screen."),
                .image(data: "abc123", mimeType: "image/png")
            ],
            responseSchema: .object(["type": .string("object")])
        )

        let prepared = try client.prepareRequest(body: body)
        let object = try decodeJSONObject(prepared.body)
        let bodyString = String(decoding: prepared.body, as: UTF8.self)

        XCTAssertEqual(prepared.url, "https://generativelanguage.googleapis.com/v1/interactions")
        XCTAssertEqual(prepared.headers["x-goog-api-key"], "secret-key")
        XCTAssertEqual(prepared.headers["Content-Type"], "application/json")
        XCTAssertFalse(prepared.url.contains("secret-key"))
        XCTAssertFalse(bodyString.contains("secret-key"))

        XCTAssertEqual(object["model"] as? String, GDAContract.defaultModel)
        XCTAssertEqual(object["system_instruction"] as? String, "Return JSON only.")
        XCTAssertEqual(object["store"] as? Bool, false)
        XCTAssertNil(object["output_text"])
        XCTAssertNil(object["usage_metadata"])

        let input = try XCTUnwrap(object["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["type"] as? String, "user_input")
        XCTAssertNil(input[0]["text"])
        XCTAssertNil(input[0]["data"])
        XCTAssertNil(input[0]["mime_type"])

        let content = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertEqual(content[0]["text"] as? String, "Describe this screen.")
        XCTAssertEqual(content[1]["type"] as? String, "image")
        XCTAssertEqual(content[1]["data"] as? String, "abc123")
        XCTAssertEqual(content[1]["mime_type"] as? String, "image/png")

        let responseFormat = try XCTUnwrap(object["response_format"] as? [String: Any])
        let schema = try XCTUnwrap(responseFormat["schema"] as? [String: Any])
        XCTAssertEqual(responseFormat["type"] as? String, "text")
        XCTAssertEqual(responseFormat["mime_type"] as? String, "application/json")
        XCTAssertEqual(schema["type"] as? String, "object")
        XCTAssertEqual((object["generation_config"] as? [String: Any])?["temperature"] as? Double, 0.0)
    }

    func testPreparedTextRequestAlsoUsesUserInputStep() throws {
        let client = GeminiVisionClient(apiKey: "secret-key")
        let body = client.makeInteractionRequest(
            model: GDAContract.defaultModel,
            systemInstruction: "Return JSON only.",
            input: [.text("Analyze the design memory.")],
            responseSchema: .object(["type": .string("object")])
        )

        let prepared = try client.prepareRequest(body: body)
        let object = try decodeJSONObject(prepared.body)
        let input = try XCTUnwrap(object["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["type"] as? String, "user_input")

        let content = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertEqual(content[0]["text"] as? String, "Analyze the design memory.")
    }

    func testInteractionRequestDecodesNestedWireInputIntoPublicContentAPI() throws {
        let client = GeminiVisionClient(apiKey: "secret-key")
        let body = client.makeInteractionRequest(
            model: GDAContract.defaultModel,
            systemInstruction: "Return JSON only.",
            input: [.text("Analyze"), .image(data: "abc123", mimeType: "image/png")],
            responseSchema: .object(["type": .string("object")])
        )

        let decoded = try JSON.decoder.decode(GeminiInteractionRequest.self, from: client.prepareRequest(body: body).body)
        XCTAssertEqual(decoded.input.count, 2)
        guard case .text(let text) = decoded.input[0] else {
            return XCTFail("Expected public text content")
        }
        XCTAssertEqual(text, "Analyze")
        guard case .image(let data, let mimeType) = decoded.input[1] else {
            return XCTFail("Expected public image content")
        }
        XCTAssertEqual(data, "abc123")
        XCTAssertEqual(mimeType, "image/png")
    }

    func testPreparedRequestThrowsBeforeHTTPWhenAPIKeyMissing() throws {
        let client = GeminiVisionClient(apiKey: "")
        let body = client.makeInteractionRequest(
            model: GDAContract.defaultModel,
            systemInstruction: "Return JSON only.",
            input: [.text("Analyze")],
            responseSchema: .object(["type": .string("object")])
        )

        XCTAssertThrowsError(try client.prepareRequest(body: body)) { error in
            guard case GeminiError.apiKeyMissing = error else {
                return XCTFail("Expected apiKeyMissing, got \(error)")
            }
        }
    }

    func testCompletedResponseUsesLastModelOutputAndUsage() throws {
        let client = GeminiVisionClient(apiKey: "test-key")
        let response = try client.parseInteractionResponse(InteractionsV1Fixtures.completed, model: GDAContract.defaultModel)

        XCTAssertEqual(response.text, #"{"ok":true}"#)
        XCTAssertEqual(response.usage?.inputTokenCount, 7)
        XCTAssertEqual(response.usage?.outputTokenCount, 20)
        XCTAssertEqual(response.usage?.totalTokenCount, 27)
    }

    func testUsageDecodesThoughtCachedAndPreservesUnknownFields() throws {
        let client = GeminiVisionClient(apiKey: "test-key")
        let response = try client.parseInteractionResponse(
            #"""
            {
              "status": "completed",
              "steps": [{"type":"model_output","content":[{"type":"text","text":"{}"}]}],
              "usage": {
                "total_input_tokens": 100,
                "total_output_tokens": 300,
                "total_thought_tokens": 50,
                "total_cached_tokens": 25,
                "total_tokens": 475,
                "future_usage_detail": {"count": 9}
              }
            }
            """#,
            model: GDAContract.defaultModel
        )

        XCTAssertEqual(response.usage?.inputTokenCount, 100)
        XCTAssertEqual(response.usage?.outputTokenCount, 300)
        XCTAssertEqual(response.usage?.thoughtTokenCount, 50)
        XCTAssertEqual(response.usage?.cachedTokenCount, 25)
        XCTAssertEqual(response.usage?.totalTokenCount, 475)
        XCTAssertTrue(response.usage?.rawJSONString?.contains("future_usage_detail") == true)
        XCTAssertTrue(response.usage?.rawJSONString?.contains("\"count\":9") == true)
    }

    func testCompletedResponseSelectsLastModelOutputOnly() throws {
        let client = GeminiVisionClient(apiKey: "test-key")
        let response = try client.parseInteractionResponse(
            #"""
            {
              "status": "completed",
              "steps": [
                { "type": "model_output", "content": [{ "type": "text", "text": "first" }] },
                { "type": "model_output", "content": [{ "type": "text", "text": "second" }, { "type": "text", "text": " output" }] }
              ]
            }
            """#,
            model: GDAContract.defaultModel
        )

        XCTAssertEqual(response.text, "second output")
    }

    func testInteractionStatusesAreNotImplicitSuccess() throws {
        let client = GeminiVisionClient(apiKey: "test-key")

        assertGeminiError(.interactionIncomplete(""), from: #"{"status":"incomplete","steps":[{"type":"model_output","content":[{"type":"text","text":"partial"}]}]}"#, client: client)
        assertGeminiError(.interactionFailed(""), from: #"{"status":"failed"}"#, client: client)
        assertGeminiError(.interactionCancelled, from: #"{"status":"cancelled"}"#, client: client)
        assertGeminiError(.unsupportedInteractionState("requires_action"), from: #"{"status":"requires_action"}"#, client: client)
        assertGeminiError(.invalidSynchronousInteractionState, from: #"{"status":"in_progress"}"#, client: client)
        assertGeminiError(.unsupportedInteractionState("future_value"), from: #"{"status":"future_value"}"#, client: client)

        XCTAssertThrowsError(try client.parseInteractionResponse(#"{"steps":[]}"#, model: GDAContract.defaultModel)) { error in
            guard case GeminiError.invalidJSON = error else {
                return XCTFail("Expected invalidJSON for missing required status, got \(error)")
            }
        }
    }

    func testSuccessfulDecodeDoesNotRedactAPIKeySubstrings() throws {
        let client = GeminiVisionClient(apiKey: "alpha")
        let response = try client.parseInteractionResponse(
            #"{"status":"completed","steps":[{"type":"model_output","content":[{"type":"text","text":"alpha is valid output"}]}]}"#,
            model: GDAContract.defaultModel
        )
        XCTAssertEqual(response.text, "alpha is valid output")
    }

    func testRetriesRateLimitUsingRetryAfterSeconds() async throws {
        let transport = ScriptedTransport([
            .response(GeminiHTTPResponse(statusCode: 429, body: Data(InteractionsV1Fixtures.rateLimitedError.utf8), headers: ["Retry-After": "1"])),
            .response(GeminiHTTPResponse(statusCode: 200, body: Data(InteractionsV1Fixtures.completed.utf8)))
        ])
        let sleeper = SleepRecorder()
        let client = GeminiVisionClient(
            apiKey: "test-key",
            baseURL: URL(string: "https://example.test")!,
            transport: transport,
            timeoutSeconds: 1,
            sleeper: { duration in await sleeper.record(duration) }
        )

        let response = try await client.analyzeText(
            model: GDAContract.defaultModel,
            systemInstruction: "Return JSON.",
            userPrompt: "Analyze",
            responseSchema: .object(["type": .string("object")])
        )

        XCTAssertEqual(response.text, #"{"ok":true}"#)
        let requestCount = await transport.requestCount()
        let durations = await sleeper.durations()
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(durations, [.seconds(1)])
    }

    func testRetryAfterLongerThanOneMinuteReturnsRateLimitWithoutSleeping() async throws {
        let transport = ScriptedTransport([
            .response(GeminiHTTPResponse(statusCode: 429, body: Data(InteractionsV1Fixtures.rateLimitedError.utf8), headers: ["Retry-After": "61"]))
        ])
        let sleeper = SleepRecorder()
        let client = testClient(transport: transport, sleeper: sleeper)

        do {
            _ = try await client.analyzeText(model: GDAContract.defaultModel, systemInstruction: "Return JSON.", userPrompt: "Analyze", responseSchema: .object(["type": .string("object")]))
            XCTFail("Expected rate limit error")
        } catch let GeminiError.rateLimited(retryAfterSeconds) {
            XCTAssertEqual(retryAfterSeconds, 61)
        }
        let requestCount = await transport.requestCount()
        let durations = await sleeper.durations()
        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(durations.isEmpty)
    }

    func testQuotaExhausted429IsDistinctFromGenericRateLimit() async throws {
        let transport = ScriptedTransport([
            .response(GeminiHTTPResponse(statusCode: 429, body: Data(InteractionsV1Fixtures.quotaExhaustedError.utf8)))
        ])
        let client = testClient(transport: transport, sleeper: SleepRecorder())

        do {
            _ = try await client.analyzeText(model: GDAContract.defaultModel, systemInstruction: "Return JSON.", userPrompt: "Analyze", responseSchema: .object(["type": .string("object")]))
            XCTFail("Expected quota exhaustion")
        } catch let GeminiError.quotaExhausted(message) {
            XCTAssertEqual(message, "Daily quota exhausted")
        }
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testRetriesRateLimitUsingHTTPDateRetryAfter() async throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        let retryAfter = formatter.string(from: Date().addingTimeInterval(3))
        let transport = ScriptedTransport([
            .response(GeminiHTTPResponse(statusCode: 429, body: Data(InteractionsV1Fixtures.rateLimitedError.utf8), headers: ["retry-after": retryAfter])),
            .response(GeminiHTTPResponse(statusCode: 200, body: Data(InteractionsV1Fixtures.completed.utf8)))
        ])
        let sleeper = SleepRecorder()
        let client = testClient(transport: transport, sleeper: sleeper)

        _ = try await client.analyzeText(model: GDAContract.defaultModel, systemInstruction: "Return JSON.", userPrompt: "Analyze", responseSchema: .object(["type": .string("object")]))

        let durations = await sleeper.durations()
        XCTAssertEqual(durations.count, 1)
        XCTAssertGreaterThanOrEqual(durations[0].components.seconds, 0)
        XCTAssertLessThanOrEqual(durations[0].components.seconds, 60)
    }

    func testStructuredErrorEnvelopeMapsSafetyCode() async throws {
        let transport = ScriptedTransport([
            .response(GeminiHTTPResponse(statusCode: 400, body: Data(InteractionsV1Fixtures.safetyError.utf8)))
        ])
        let client = testClient(transport: transport, sleeper: SleepRecorder())

        do {
            _ = try await client.analyzeText(model: GDAContract.defaultModel, systemInstruction: "Return JSON.", userPrompt: "Analyze", responseSchema: .object(["type": .string("object")]))
            XCTFail("Expected content block")
        } catch let GeminiError.contentBlocked(code) {
            XCTAssertEqual(code, "CONTENT_BLOCKED")
        }
    }

    func testStructuredServerErrorPreservesDocumentedErrorMessage() async throws {
        let body = Data(#"{"error":{"code":"internal","message":"service unavailable"}}"#.utf8)
        let transport = ScriptedTransport(Array(repeating: .response(GeminiHTTPResponse(statusCode: 503, body: body)), count: 6))
        let sleeper = SleepRecorder()
        let client = testClient(transport: transport, sleeper: sleeper)

        do {
            _ = try await client.analyzeText(model: GDAContract.defaultModel, systemInstruction: "Return JSON.", userPrompt: "Analyze", responseSchema: .object(["type": .string("object")]))
            XCTFail("Expected server error")
        } catch let GeminiError.httpError(statusCode, details) {
            XCTAssertEqual(statusCode, 503)
            XCTAssertEqual(details, "service unavailable")
        }
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 6)
    }

    func testCancellationAndPermanentTransportFailureAreNotRetried() async throws {
        let cancellationTransport = ScriptedTransport([.cancelled])
        let cancellationSleeper = SleepRecorder()
        let cancellationClient = testClient(transport: cancellationTransport, sleeper: cancellationSleeper)

        await XCTAssertThrowsErrorAsync(try await cancellationClient.analyzeText(model: GDAContract.defaultModel, systemInstruction: "Return JSON.", userPrompt: "Analyze", responseSchema: .object(["type": .string("object")]))) { error in
            XCTAssertTrue(error is CancellationError)
        }
        let cancellationRequestCount = await cancellationTransport.requestCount()
        let cancellationDurations = await cancellationSleeper.durations()
        XCTAssertEqual(cancellationRequestCount, 1)
        XCTAssertTrue(cancellationDurations.isEmpty)

        let failureTransport = ScriptedTransport([.urlError(.badURL)])
        let failureClient = testClient(transport: failureTransport, sleeper: SleepRecorder())
        await XCTAssertThrowsErrorAsync(try await failureClient.analyzeText(model: GDAContract.defaultModel, systemInstruction: "Return JSON.", userPrompt: "Analyze", responseSchema: .object(["type": .string("object")]))) { error in
            guard case GeminiError.connectionFailed = error else {
                return XCTFail("Expected connectionFailed, got \(error)")
            }
        }
        let failureRequestCount = await failureTransport.requestCount()
        XCTAssertEqual(failureRequestCount, 1)
    }

    private func assertGeminiError(_ expected: GeminiError, from response: String, client: GeminiVisionClient, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try client.parseInteractionResponse(response, model: GDAContract.defaultModel), file: file, line: line) { error in
            switch (expected, error) {
            case (.interactionIncomplete, GeminiError.interactionIncomplete),
                 (.interactionFailed, GeminiError.interactionFailed),
                 (.interactionCancelled, GeminiError.interactionCancelled),
                 (.invalidSynchronousInteractionState, GeminiError.invalidSynchronousInteractionState),
                 (.unsupportedInteractionState, GeminiError.unsupportedInteractionState):
                break
            default:
                XCTFail("Unexpected error \(error)", file: file, line: line)
            }
        }
    }

    private func testClient(transport: HTTPTransport, sleeper: SleepRecorder) -> GeminiVisionClient {
        GeminiVisionClient(
            apiKey: "test-key",
            baseURL: URL(string: "https://example.test")!,
            transport: transport,
            timeoutSeconds: 1,
            sleeper: { duration in await sleeper.record(duration) }
        )
    }

    private func decodeJSONObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private actor SleepRecorder {
    private var recordedDurations: [Duration] = []

    func record(_ duration: Duration) {
        recordedDurations.append(duration)
    }

    func durations() -> [Duration] {
        recordedDurations
    }
}

private enum ScriptedOutcome: Sendable {
    case response(GeminiHTTPResponse)
    case urlError(URLError.Code)
    case cancelled
}

private actor ScriptedTransport: HTTPTransport {
    private var outcomes: [ScriptedOutcome]
    private var requests: [GeminiHTTPRequest] = []

    init(_ outcomes: [ScriptedOutcome]) {
        self.outcomes = outcomes
    }

    func execute(_ request: GeminiHTTPRequest) async throws -> GeminiHTTPResponse {
        requests.append(request)
        guard !outcomes.isEmpty else {
            throw URLError(.badServerResponse)
        }
        switch outcomes.removeFirst() {
        case .response(let response):
            return response
        case .urlError(let code):
            throw URLError(code)
        case .cancelled:
            throw CancellationError()
        }
    }

    func requestCount() -> Int {
        requests.count
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> some Any,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ handler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}
