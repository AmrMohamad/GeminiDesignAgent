import XCTest
@testable import GeminiDesignAgentCore

final class GeminiLiveSmokeTests: XCTestCase {
    func testLiveGeminiInteractionReturnsDecodableDesignAnalysisWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["GDA_LIVE_GEMINI_TESTS"] == "1" else {
            throw XCTSkip("Set GDA_LIVE_GEMINI_TESTS=1 to run live Gemini smoke tests.")
        }
        guard let apiKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XCTSkip("Set GEMINI_API_KEY to run live Gemini smoke tests.")
        }

        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gda-live-smoke-\(UUID().uuidString).png")
        try onePixelPNG.write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let client = GeminiVisionClient(apiKey: apiKey, timeoutSeconds: 60)
        let response = try await client.analyzeImage(
            model: ProcessInfo.processInfo.environment["GDA_LIVE_GEMINI_MODEL"] ?? GDAContract.defaultModel,
            imageURL: imageURL,
            mimeType: "image/png",
            systemInstruction: "Return JSON only.",
            userPrompt: "Return a valid DesignAnalysis JSON object for this tiny test image. Use empty arrays where details are not visible.",
            responseSchema: GeminiJSONSchema.designAnalysis
        )

        _ = try JSON.decoder.decode(DesignAnalysis.self, from: response.data)
    }

    private var onePixelPNG: Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=")!
    }
}
