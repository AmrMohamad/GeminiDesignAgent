import XCTest
@testable import GeminiDesignAgentCore

final class ModelFallbackAnalyzerTests: XCTestCase {
    func testFallsBackOnlyAfterModelUnavailableAndMakesFallbackSticky() async throws {
        let base = ScriptedAnalyzer(results: [
            .failure(GeminiError.modelNotFound("missing")),
            .success(Self.response(model: "ignored")),
            .success(Self.response(model: "ignored"))
        ])
        let analyzer = ModelFallbackAnalyzer(base: base, fallbacks: ["gemini-fallback"])

        let first = try await analyzer.analyzeText(
            model: "gemini-primary",
            systemInstruction: "system",
            userPrompt: "user",
            responseSchema: .object([:])
        )
        let second = try await analyzer.analyzeText(
            model: "gemini-primary",
            systemInstruction: "system",
            userPrompt: "repair",
            responseSchema: .object([:])
        )

        XCTAssertEqual(first.model, "gemini-fallback")
        XCTAssertEqual(second.model, "gemini-fallback")
        let requested = await base.models()
        let attempted = await analyzer.attemptedModels()
        XCTAssertEqual(requested, ["gemini-primary", "gemini-fallback", "gemini-fallback"])
        XCTAssertEqual(attempted, ["gemini-fallback"])
    }

    func testProjectQuotaDoesNotSwitchModels() async throws {
        let base = ScriptedAnalyzer(results: [.failure(GeminiError.quotaExhausted("project quota"))])
        let analyzer = ModelFallbackAnalyzer(base: base, fallbacks: ["gemini-fallback"])

        do {
            _ = try await analyzer.analyzeText(
                model: "gemini-primary",
                systemInstruction: "system",
                userPrompt: "user",
                responseSchema: .object([:])
            )
            XCTFail("Expected project quota error")
        } catch let GeminiError.quotaExhausted(message) {
            XCTAssertEqual(message, "project quota")
        }
        let requested = await base.models()
        XCTAssertEqual(requested, ["gemini-primary"])
    }

    func testModelScopedQuotaCanUseConfiguredFallback() async throws {
        let base = ScriptedAnalyzer(results: [
            .failure(GeminiError.modelQuotaExhausted("model quota")),
            .success(Self.response(model: "ignored"))
        ])
        let analyzer = ModelFallbackAnalyzer(base: base, fallbacks: ["gemini-fallback"])

        let result = try await analyzer.analyzeText(
            model: "gemini-primary",
            systemInstruction: "system",
            userPrompt: "user",
            responseSchema: .object([:])
        )

        XCTAssertEqual(result.model, "gemini-fallback")
        let requested = await base.models()
        XCTAssertEqual(requested, ["gemini-primary", "gemini-fallback"])
    }

    private static func response(model: String) -> GeminiRawTextResponse {
        GeminiRawTextResponse(text: "{}", data: Data("{}".utf8), model: model, usage: nil)
    }

    private actor ScriptedAnalyzer: GeminiDesignAnalyzing {
        private var results: [Result<GeminiRawTextResponse, Error>]
        private var requestedModels: [String] = []

        init(results: [Result<GeminiRawTextResponse, Error>]) {
            self.results = results
        }

        func models() -> [String] { requestedModels }

        func analyzeImage(model: String, imageURL: URL, mimeType: String, systemInstruction: String, userPrompt: String, responseSchema: JSONValue) async throws -> GeminiRawTextResponse {
            try next(model: model)
        }

        func analyzeText(model: String, systemInstruction: String, userPrompt: String, responseSchema: JSONValue) async throws -> GeminiRawTextResponse {
            try next(model: model)
        }

        private func next(model: String) throws -> GeminiRawTextResponse {
            requestedModels.append(model)
            guard !results.isEmpty else { throw GeminiError.unexpectedResponse("missing scripted result") }
            return try results.removeFirst().get()
        }
    }
}
