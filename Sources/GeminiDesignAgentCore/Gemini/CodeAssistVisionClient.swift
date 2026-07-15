import Foundation

public final class CodeAssistVisionClient: GeminiDesignAnalyzing, @unchecked Sendable {
    private let client: CodeAssistClient
    private let enabledCreditTypes: [String]?
    private static let maxInlineRequestBytes = 20 * 1024 * 1024

    public init(client: CodeAssistClient, enabledCreditTypes: [String]? = nil) {
        self.client = client
        self.enabledCreditTypes = enabledCreditTypes
    }

    public func analyzeImage(
        model: String,
        imageURL: URL,
        mimeType: String,
        systemInstruction: String,
        userPrompt: String,
        responseSchema: JSONValue
    ) async throws -> GeminiRawTextResponse {
        let resolvedModel = CodeAssistModelResolver.resolve(model)
        let imageData = try Data(contentsOf: imageURL)
        let base64 = imageData.base64EncodedString()

        let contents = CodeAssist.GeminiContent(role: "user", parts: [
            .text(userPrompt),
            .inlineData(mimeType: mimeType, data: base64)
        ])
        let systemContent = CodeAssist.GeminiContent(role: "user", parts: [.text(systemInstruction)])

        let genConfig = CodeAssist.VertexGenerationConfig(
            responseMimeType: "application/json",
            responseJsonSchema: responseSchema
        )

        try validateRequestSize(
            contents: [contents],
            model: resolvedModel,
            systemInstruction: systemContent,
            generationConfig: genConfig,
            enabledCreditTypes: enabledCreditTypes
        )

        let response = try await client.generateContent(
            contents: [contents],
            model: resolvedModel,
            systemInstruction: systemContent,
            generationConfig: genConfig,
            enabledCreditTypes: enabledCreditTypes
        )

        guard let text = await client.extractText(from: response) else {
            if let blockReason = response.response?.promptFeedback?.blockReason {
                throw GeminiError.contentBlocked(blockReason)
            }
            let body = (try? JSON.compactEncoder.encode(response)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw GeminiError.noTextOutput(String(body.prefix(500)))
        }

        return GeminiRawTextResponse(
            text: text,
            data: Data(text.utf8),
            model: resolvedModel,
            usage: await client.extractUsage(from: response),
            googleOneAICreditBalance: Self.googleOneAICreditBalance(response.remainingCredits)
        )
    }

    public func analyzeText(
        model: String,
        systemInstruction: String,
        userPrompt: String,
        responseSchema: JSONValue
    ) async throws -> GeminiRawTextResponse {
        let resolvedModel = CodeAssistModelResolver.resolve(model)
        let contents = CodeAssist.GeminiContent(role: "user", parts: [.text(userPrompt)])
        let systemContent = CodeAssist.GeminiContent(role: "user", parts: [.text(systemInstruction)])

        let genConfig = CodeAssist.VertexGenerationConfig(
            responseMimeType: "application/json",
            responseJsonSchema: responseSchema
        )

        try validateRequestSize(
            contents: [contents],
            model: resolvedModel,
            systemInstruction: systemContent,
            generationConfig: genConfig,
            enabledCreditTypes: enabledCreditTypes
        )

        let response = try await client.generateContent(
            contents: [contents],
            model: resolvedModel,
            systemInstruction: systemContent,
            generationConfig: genConfig,
            enabledCreditTypes: enabledCreditTypes
        )

        guard let text = await client.extractText(from: response) else {
            if let blockReason = response.response?.promptFeedback?.blockReason {
                throw GeminiError.contentBlocked(blockReason)
            }
            let body = (try? JSON.compactEncoder.encode(response)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw GeminiError.noTextOutput(String(body.prefix(500)))
        }

        return GeminiRawTextResponse(
            text: text,
            data: Data(text.utf8),
            model: resolvedModel,
            usage: await client.extractUsage(from: response),
            googleOneAICreditBalance: Self.googleOneAICreditBalance(response.remainingCredits)
        )
    }

    private func validateRequestSize(
        contents: [CodeAssist.GeminiContent],
        model: String,
        systemInstruction: CodeAssist.GeminiContent?,
        generationConfig: CodeAssist.VertexGenerationConfig?,
        enabledCreditTypes: [String]?
    ) throws {
        var vertexRequest = CodeAssist.VertexGenerateContentRequest(
            contents: contents,
            systemInstruction: systemInstruction,
            generationConfig: generationConfig
        )
        vertexRequest.sessionId = UUID().uuidString.lowercased()
        let request = CodeAssist.GenerateContentRequest(
            model: model,
            project: nil,
            request: vertexRequest,
            enabledCreditTypes: enabledCreditTypes
        )
        let bodyData = try JSON.compactEncoder.encode(request)
        guard bodyData.count <= Self.maxInlineRequestBytes else {
            throw GeminiError.requestTooLarge(bodyData.count)
        }
    }

    private static func googleOneAICreditBalance(_ credits: [CodeAssist.Credits]?) -> Int? {
        let matching = credits?.filter { $0.creditType == CodeAssist.CreditType.googleOneAI.rawValue } ?? []
        guard !matching.isEmpty else { return nil }
        return matching.reduce(0) { $0 + (Int($1.creditAmount) ?? 0) }
    }
}
