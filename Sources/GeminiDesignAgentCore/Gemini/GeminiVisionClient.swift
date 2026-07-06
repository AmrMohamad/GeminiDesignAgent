import Foundation
import AsyncHTTPClient

public final class GeminiVisionClient: Sendable {
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

        let requestBody = GeminiInteractionRequest(
            model: model,
            systemInstruction: systemInstruction,
            input: [
                .text(userPrompt),
                .imageData(data: base64, mimeType: mimeType)
            ],
            responseFormat: .jsonSchema(responseSchema),
            generationConfig: GeminiGenerationConfig(temperature: 0.0)
        )

        return try await postInteraction(requestBody)
    }

    public func analyzeText(
        model: String,
        systemInstruction: String,
        userPrompt: String,
        responseSchema: JSONValue
    ) async throws -> GeminiRawTextResponse {
        let requestBody = GeminiInteractionRequest(
            model: model,
            systemInstruction: systemInstruction,
            input: [.text(userPrompt)],
            responseFormat: .jsonSchema(responseSchema),
            generationConfig: GeminiGenerationConfig(temperature: 0.0)
        )

        return try await postInteraction(requestBody)
    }

    private func postInteraction(_ body: GeminiInteractionRequest, attempt: Int = 0) async throws -> GeminiRawTextResponse {
        let maxRetries = 5
        let url = baseURL.appendingPathComponent("v1beta/models/\(body.model):generateContent")

        var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        urlComponents.queryItems = [URLQueryItem(name: "key", value: apiKey)]

        guard let finalURL = urlComponents.url else {
            throw GeminiError.invalidURL
        }

        let bodyData = try JSON.compactEncoder.encode(body)

        var request = HTTPClientRequest(url: finalURL.absoluteString)
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/json")
        request.body = .bytes(bodyData)

        let response: HTTPClientResponse
        do {
            response = try await httpClient.execute(request, timeout: .seconds(Int64(timeoutSeconds)))
        } catch {
            if attempt < maxRetries {
                try await backoff(attempt: attempt)
                return try await postInteraction(body, attempt: attempt + 1)
            }
            throw GeminiError.timeout
        }

        let responseBody = try await response.body.collect(upTo: 10 * 1024 * 1024)
        let responseString = sanitizeResponse(String(buffer: responseBody))

        switch response.status {
        case .ok:
            guard let data = responseString.data(using: .utf8),
                  let geminiResponse = try? JSON.decoder.decode(GeminiInteractionResponse.self, from: data),
                  let text = geminiResponse.candidates?.first?.content?.parts?.first?.text else {
                throw GeminiError.invalidJSON("Could not parse Gemini response: \(responseString.prefix(500))")
            }

            return GeminiRawTextResponse(
                text: text,
                data: Data(text.utf8),
                model: body.model,
                tokenCount: geminiResponse.usageMetadata
            )

        case .tooManyRequests:
            if attempt < maxRetries {
                try await backoff(attempt: attempt)
                return try await postInteraction(body, attempt: attempt + 1)
            }
            throw GeminiError.rateLimited

        case .internalServerError, .badGateway, .serviceUnavailable, .gatewayTimeout:
            if attempt < maxRetries {
                try await backoff(attempt: attempt)
                return try await postInteraction(body, attempt: attempt + 1)
            }
            throw GeminiError.httpError(statusCode: Int(response.status.code), body: responseString)

        case .badRequest:
            throw GeminiError.httpError(statusCode: 400, body: responseString)

        case .unauthorized:
            throw GeminiError.httpError(statusCode: 401, body: responseString)

        case .forbidden:
            throw GeminiError.httpError(statusCode: 403, body: responseString)

        default:
            throw GeminiError.httpError(statusCode: Int(response.status.code), body: responseString)
        }
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
