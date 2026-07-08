import Foundation
import AsyncHTTPClient

public protocol GeminiDesignAnalyzing: Sendable {
    func analyzeImage(
        model: String,
        imageURL: URL,
        mimeType: String,
        systemInstruction: String,
        userPrompt: String,
        responseSchema: JSONValue
    ) async throws -> GeminiRawTextResponse

    func analyzeText(
        model: String,
        systemInstruction: String,
        userPrompt: String,
        responseSchema: JSONValue
    ) async throws -> GeminiRawTextResponse
}

public struct GeminiPreparedRequest: Sendable {
    public var url: String
    public var headers: [String: String]
    public var body: Data
}

public final class GeminiVisionClient: GeminiDesignAnalyzing {
    public let apiKey: String
    public let baseURL: URL
    public let httpClient: HTTPClient
    public let timeoutSeconds: Int

    public init(
        apiKey: String,
        baseURL: URL = URL(string: "https://generativelanguage.googleapis.com")!,
        httpClient: HTTPClient = .shared,
        timeoutSeconds: Int = 120
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.httpClient = httpClient
        self.timeoutSeconds = timeoutSeconds
    }

    public func analyzeImage(
        model: String,
        imageURL: URL,
        mimeType: String,
        systemInstruction: String,
        userPrompt: String,
        responseSchema: JSONValue
    ) async throws -> GeminiRawTextResponse {
        let imageData = try Data(contentsOf: imageURL)
        let maxInlineBytes = 20 * 1024 * 1024

        guard imageData.count <= maxInlineBytes else {
            throw GeminiError.imageTooLarge(imageData.count)
        }

        let base64 = imageData.base64EncodedString()

        let requestBody = makeGenerateContentRequest(
            systemInstruction: systemInstruction,
            parts: [
                .text(userPrompt),
                .imageData(data: base64, mimeType: mimeType)
            ],
            responseSchema: responseSchema
        )

        return try await postGenerateContent(model: model, body: requestBody)
    }

    public func analyzeText(
        model: String,
        systemInstruction: String,
        userPrompt: String,
        responseSchema: JSONValue
    ) async throws -> GeminiRawTextResponse {
        let requestBody = makeGenerateContentRequest(
            systemInstruction: systemInstruction,
            parts: [.text(userPrompt)],
            responseSchema: responseSchema
        )

        return try await postGenerateContent(model: model, body: requestBody)
    }

    public func makeGenerateContentRequest(
        systemInstruction: String,
        parts: [GeminiInputPart],
        responseSchema: JSONValue
    ) -> GeminiGenerateContentRequest {
        let foldedSystemPrompt = """
        SYSTEM:
        \(systemInstruction)

        USER:
        """

        let contentParts = [GeminiInputPart.text(foldedSystemPrompt)].map { $0.contentPart }
            + parts.map { $0.contentPart }

        return GeminiGenerateContentRequest(
            contents: [GeminiContent(parts: contentParts)],
            generationConfig: GeminiGenerationConfig(
                temperature: 0.0,
                responseFormat: [.jsonSchema(responseSchema.uppercasingSchemaTypes())]
            )
        )
    }

    public func prepareRequest(model: String, body: GeminiGenerateContentRequest) throws -> GeminiPreparedRequest {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GeminiError.apiKeyMissing
        }

        let url = baseURL.appendingPathComponent("v1beta/models/\(model):generateContent")
        let bodyData = try JSON.compactEncoder.encode(body)
        return GeminiPreparedRequest(
            url: url.absoluteString,
            headers: [
                "Content-Type": "application/json",
                "x-goog-api-key": apiKey
            ],
            body: bodyData
        )
    }

    private func postGenerateContent(model: String, body: GeminiGenerateContentRequest, attempt: Int = 0) async throws -> GeminiRawTextResponse {
        let maxRetries = 5
        let prepared = try prepareRequest(model: model, body: body)

        var request = HTTPClientRequest(url: prepared.url)
        request.method = .POST
        for (name, value) in prepared.headers {
            request.headers.add(name: name, value: value)
        }
        request.body = .bytes(prepared.body)

        let response: HTTPClientResponse
        do {
            response = try await httpClient.execute(request, timeout: .seconds(Int64(timeoutSeconds)))
        } catch {
            if attempt < maxRetries {
                try await backoff(attempt: attempt)
                return try await postGenerateContent(model: model, body: body, attempt: attempt + 1)
            }
            throw GeminiError.timeout
        }

        let responseBody = try await response.body.collect(upTo: 10 * 1024 * 1024)
        let responseString = sanitizeResponse(String(buffer: responseBody))

        switch response.status {
        case .ok:
            return try parseGenerateContentResponse(responseString, model: model)

        case .tooManyRequests:
            if isQuotaExhausted(responseString) {
                throw GeminiError.quotaExhausted(responseString)
            }
            if attempt < maxRetries {
                try await backoff(attempt: attempt)
                return try await postGenerateContent(model: model, body: body, attempt: attempt + 1)
            }
            throw GeminiError.rateLimited

        case .internalServerError, .badGateway, .serviceUnavailable, .gatewayTimeout:
            if attempt < maxRetries {
                try await backoff(attempt: attempt)
                return try await postGenerateContent(model: model, body: body, attempt: attempt + 1)
            }
            throw GeminiError.httpError(statusCode: Int(response.status.code), body: responseString)

        case .badRequest:
            if isModelNotFound(responseString) {
                throw GeminiError.modelNotFound(responseString)
            }
            throw GeminiError.httpError(statusCode: 400, body: responseString)

        case .unauthorized:
            throw GeminiError.invalidAPIKey(responseString)

        case .forbidden:
            if isBillingDisabled(responseString) {
                throw GeminiError.billingDisabled(responseString)
            }
            throw GeminiError.httpError(statusCode: 403, body: responseString)

        default:
            if Int(response.status.code) == 404 && isModelNotFound(responseString) {
                throw GeminiError.modelNotFound(responseString)
            }
            throw GeminiError.httpError(statusCode: Int(response.status.code), body: responseString)
        }
    }

    public func parseGenerateContentResponse(_ responseString: String, model: String) throws -> GeminiRawTextResponse {
        guard let data = responseString.data(using: .utf8) else {
            throw GeminiError.invalidJSON("Gemini response was not UTF-8")
        }

        let geminiResponse: GeminiInteractionResponse
        do {
            geminiResponse = try JSON.decoder.decode(GeminiInteractionResponse.self, from: data)
        } catch {
            throw GeminiError.invalidJSON("Could not decode Gemini response: \(error). Body prefix: \(responseString.prefix(500))")
        }

        guard let candidates = geminiResponse.candidates, !candidates.isEmpty else {
            throw GeminiError.noCandidates(String(responseString.prefix(500)))
        }

        let first = candidates[0]
        let finishReason = first.finishReason ?? "UNKNOWN"
        switch finishReason.uppercased() {
        case "SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII":
            throw GeminiError.contentBlocked(finishReason)
        case "MAX_TOKENS":
            throw GeminiError.maxTokensTruncated("finishReason=MAX_TOKENS")
        default:
            break
        }

        guard let text = first.content?.parts?.compactMap(\.text).first(where: { !$0.isEmpty }) else {
            throw GeminiError.unexpectedResponse("Candidate had finishReason=\(finishReason) but no text part")
        }

        return GeminiRawTextResponse(
            text: text,
            data: Data(text.utf8),
            model: model,
            tokenCount: geminiResponse.usageMetadata
        )
    }

    private func isQuotaExhausted(_ body: String) -> Bool {
        let lower = body.lowercased()
        return lower.contains("resource_exhausted") || lower.contains("quota")
    }

    private func isModelNotFound(_ body: String) -> Bool {
        let lower = body.lowercased()
        return lower.contains("model") && (lower.contains("not found") || lower.contains("not_found"))
    }

    private func isBillingDisabled(_ body: String) -> Bool {
        let lower = body.lowercased()
        return lower.contains("billing") || lower.contains("permission_denied")
    }

    private func sanitizeResponse(_ raw: String) -> String {
        raw.replacingOccurrences(of: apiKey, with: "[REDACTED]")
    }

    private func backoff(attempt: Int) async throws {
        let baseDelay = 1.0
        let delay = baseDelay * pow(2.0, Double(attempt))
        let jitter = Double.random(in: 0...1.0)
        try await Task.sleep(nanoseconds: UInt64((delay + jitter) * 1_000_000_000))
    }
}
