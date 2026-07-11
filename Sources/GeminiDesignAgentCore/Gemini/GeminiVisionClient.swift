import Foundation

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

public final class GeminiVisionClient: GeminiDesignAnalyzing, @unchecked Sendable {
    private static let endpointPath = "\(GDAContract.geminiAPIVersion)/interactions"
    private static let maxRetryDelaySeconds = 60
    private static let maxRetries = 5
    private static let maxInlineRequestBytes = 20 * 1024 * 1024

    public let apiKey: String
    public let baseURL: URL
    public let transport: HTTPTransport
    public let timeoutSeconds: Int
    private let sleeper: @Sendable (Duration) async throws -> Void
    private let retryPolicy: GeminiRetryPolicy

    public convenience init(
        apiKey: String,
        baseURL: URL = URL(string: "https://generativelanguage.googleapis.com")!,
        transport: HTTPTransport = URLSessionHTTPTransport(),
        timeoutSeconds: Int = 120
    ) {
        self.init(
            apiKey: apiKey,
            baseURL: baseURL,
            transport: transport,
            timeoutSeconds: timeoutSeconds,
            sleeper: { duration in try await Task.sleep(for: duration) },
            retryPolicy: GeminiRetryPolicy()
        )
    }

    init(
        apiKey: String,
        baseURL: URL,
        transport: HTTPTransport,
        timeoutSeconds: Int,
        sleeper: @escaping @Sendable (Duration) async throws -> Void,
        retryPolicy: GeminiRetryPolicy = GeminiRetryPolicy()
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.transport = transport
        self.timeoutSeconds = timeoutSeconds
        self.sleeper = sleeper
        self.retryPolicy = retryPolicy
    }

    public func analyzeImage(
        model: String,
        imageURL: URL,
        mimeType: String,
        systemInstruction: String,
        userPrompt: String,
        responseSchema: JSONValue
    ) async throws -> GeminiRawTextResponse {
        let values = try imageURL.resourceValues(forKeys: [.fileSizeKey])
        let fileSize = values.fileSize ?? 0
        let minimumEncodedSize = ((fileSize + 2) / 3) * 4
        guard minimumEncodedSize <= Self.maxInlineRequestBytes else {
            throw GeminiError.requestTooLarge(minimumEncodedSize)
        }
        let imageData = try Data(contentsOf: imageURL)
        let requestBody = makeInteractionRequest(
            model: model,
            systemInstruction: systemInstruction,
            input: [
                .text(userPrompt),
                .image(data: imageData.base64EncodedString(), mimeType: mimeType)
            ],
            responseSchema: responseSchema
        )

        return try await postInteraction(model: model, body: requestBody)
    }

    public func analyzeText(
        model: String,
        systemInstruction: String,
        userPrompt: String,
        responseSchema: JSONValue
    ) async throws -> GeminiRawTextResponse {
        let requestBody = makeInteractionRequest(
            model: model,
            systemInstruction: systemInstruction,
            input: [.text(userPrompt)],
            responseSchema: responseSchema
        )

        return try await postInteraction(model: model, body: requestBody)
    }

    public func makeInteractionRequest(
        model: String,
        systemInstruction: String,
        input: [GeminiInteractionInput],
        responseSchema: JSONValue
    ) -> GeminiInteractionRequest {
        GeminiInteractionRequest(
            model: model,
            systemInstruction: systemInstruction,
            input: input,
            responseFormat: .jsonSchema(responseSchema),
            generationConfig: nil
        )
    }

    public func prepareRequest(body: GeminiInteractionRequest) throws -> GeminiPreparedRequest {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GeminiError.apiKeyMissing
        }

        let url = baseURL.appendingPathComponent(Self.endpointPath)
        let bodyData = try JSON.compactEncoder.encode(body)
        guard bodyData.count <= Self.maxInlineRequestBytes else {
            throw GeminiError.requestTooLarge(bodyData.count)
        }
        return GeminiPreparedRequest(
            url: url.absoluteString,
            headers: [
                "Content-Type": "application/json",
                "x-goog-api-key": apiKey
            ],
            body: bodyData
        )
    }

    private func postInteraction(model: String, body: GeminiInteractionRequest, attempt: Int = 0) async throws -> GeminiRawTextResponse {
        let prepared = try prepareRequest(body: body)
        guard let url = URL(string: prepared.url) else {
            throw GeminiError.invalidURL
        }

        let request = GeminiHTTPRequest(
            url: url,
            method: "POST",
            headers: prepared.headers,
            body: prepared.body,
            timeoutSeconds: timeoutSeconds
        )

        let response: GeminiHTTPResponse
        do {
            response = try await transport.execute(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let mappedError = mapTransportError(error)
            if attempt < retryPolicy.maxRetries, isRetryableTransportError(error) {
                try await waitBeforeRetry(attempt: attempt, retryAfterSeconds: nil)
                return try await postInteraction(model: model, body: body, attempt: attempt + 1)
            }
            throw mappedError
        }

        let apiError = decodeAPIError(response.body)
        let diagnosticBody = diagnosticBodyPrefix(response.body)
        let errorDetails = redactedDiagnostic(apiError?.message ?? diagnosticBody)

        switch response.statusCode {
        case 200...299:
            return try parseInteractionResponse(response.body, model: model)

        case 429:
            let quotaClassification = GeminiQuotaClassifier().classify(
                httpStatus: response.statusCode,
                canonicalStatus: apiError?.canonicalStatus,
                message: apiError?.message,
                details: apiError?.detailText ?? "",
                retryAfter: retryAfterSeconds(from: response.headers).map { .seconds($0) }
            )
            if case .dailyProjectQuota = quotaClassification {
                throw GeminiError.quotaExhausted(errorDetails)
            }
            let retryAfterSeconds = retryAfterSeconds(from: response.headers)
            if attempt < retryPolicy.maxRetries {
                try await waitBeforeRetry(attempt: attempt, retryAfterSeconds: retryAfterSeconds)
                return try await postInteraction(model: model, body: body, attempt: attempt + 1)
            }
            throw GeminiError.rateLimited(retryAfterSeconds: retryAfterSeconds)

        case 500...599:
            if attempt < retryPolicy.maxRetries {
                try await waitBeforeRetry(attempt: attempt, retryAfterSeconds: retryAfterSeconds(from: response.headers))
                return try await postInteraction(model: model, body: body, attempt: attempt + 1)
            }
            throw GeminiError.httpError(statusCode: response.statusCode, body: errorDetails)

        case 400:
            if isContentBlocked(apiError) {
                throw GeminiError.contentBlocked(apiError?.explicitCode ?? "blocked")
            }
            if isModelNotFound(apiError, body: errorDetails) {
                throw GeminiError.modelNotFound(errorDetails)
            }
            throw GeminiError.httpError(statusCode: response.statusCode, body: errorDetails)

        case 401:
            throw GeminiError.invalidAPIKey(errorDetails)

        case 403:
            if isBillingDisabled(apiError, body: errorDetails) {
                throw GeminiError.billingDisabled(errorDetails)
            }
            throw GeminiError.httpError(statusCode: response.statusCode, body: errorDetails)

        case 404:
            if isModelNotFound(apiError, body: errorDetails) {
                throw GeminiError.modelNotFound(errorDetails)
            }
            throw GeminiError.httpError(statusCode: response.statusCode, body: errorDetails)

        default:
            throw GeminiError.httpError(statusCode: response.statusCode, body: errorDetails)
        }
    }

    public func parseInteractionResponse(_ responseString: String, model: String) throws -> GeminiRawTextResponse {
        try parseInteractionResponse(Data(responseString.utf8), model: model)
    }

    public func parseInteractionResponse(_ data: Data, model: String) throws -> GeminiRawTextResponse {
        let geminiResponse: GeminiInteractionResponse
        do {
            geminiResponse = try JSON.decoder.decode(GeminiInteractionResponse.self, from: data)
        } catch {
            throw GeminiError.invalidJSON("Could not decode Gemini response: \(error). Body prefix: \(diagnosticBodyPrefix(data))")
        }

        let outputText = modelOutputText(from: geminiResponse)
        switch geminiResponse.status {
        case .completed:
            guard let outputText else {
                throw GeminiError.noTextOutput(diagnosticBodyPrefix(data))
            }
            return GeminiRawTextResponse(text: outputText, data: Data(outputText.utf8), model: model, usage: geminiResponse.usage)
        case .incomplete:
            throw GeminiError.interactionIncomplete(outputText.map { String($0.prefix(500)) } ?? diagnosticBodyPrefix(data))
        case .failed:
            throw GeminiError.interactionFailed(diagnosticBodyPrefix(data))
        case .cancelled:
            throw GeminiError.interactionCancelled
        case .inProgress:
            throw GeminiError.invalidSynchronousInteractionState
        case .requiresAction, .unknown(_):
            throw GeminiError.unsupportedInteractionState(geminiResponse.status.rawValue)
        }
    }

    private func modelOutputText(from response: GeminiInteractionResponse) -> String? {
        guard let outputStep = response.steps?.last(where: { $0.type == "model_output" }) else {
            return nil
        }
        let text = (outputStep.content ?? [])
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func decodeAPIError(_ data: Data) -> GeminiAPIErrorPayload? {
        try? JSON.decoder.decode(GeminiAPIErrorEnvelope.self, from: data).error
    }

    private func isContentBlocked(_ error: GeminiAPIErrorPayload?) -> Bool {
        let code = error?.canonicalStatus?.uppercased() ?? ""
        return ["SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "CONTENT_BLOCKED"].contains(code)
    }

    private func isModelNotFound(_ error: GeminiAPIErrorPayload?, body: String) -> Bool {
        let code = error?.canonicalStatus?.lowercased() ?? ""
        let lower = body.lowercased()
        return code == "not_found" && lower.contains("model")
            || lower.contains("model") && (lower.contains("not found") || lower.contains("not_found"))
    }

    private func isBillingDisabled(_ error: GeminiAPIErrorPayload?, body: String) -> Bool {
        let code = error?.canonicalStatus?.lowercased() ?? ""
        let lower = body.lowercased()
        return code == "permission_denied" || lower.contains("billing")
    }

    private func diagnosticBodyPrefix(_ data: Data) -> String {
        let raw = String(decoding: data, as: UTF8.self)
        return redactedDiagnostic(raw)
    }

    private func redactedDiagnostic(_ value: String) -> String {
        let redacted = apiKey.isEmpty ? value : value.replacingOccurrences(of: apiKey, with: "[REDACTED]")
        return String(redacted.prefix(1_000))
    }

    private func mapTransportError(_ error: Error) -> GeminiError {
        guard let urlError = error as? URLError else {
            return .connectionFailed(error.localizedDescription)
        }
        switch urlError.code {
        case .timedOut:
            return .timeout
        case .notConnectedToInternet, .networkConnectionLost:
            return .networkUnavailable(urlError.localizedDescription)
        case .cannotFindHost, .dnsLookupFailed:
            return .dnsFailure(urlError.localizedDescription)
        default:
            return .connectionFailed(urlError.localizedDescription)
        }
    }

    private func isRetryableTransportError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    private func retryAfterSeconds(from headers: [String: String]) -> Int? {
        guard let value = headers["retry-after"]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if let seconds = Int(value), seconds >= 0 {
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        guard let retryDate = formatter.date(from: value) else { return nil }
        return max(0, Int(ceil(retryDate.timeIntervalSinceNow)))
    }

    private func waitBeforeRetry(attempt: Int, retryAfterSeconds: Int?) async throws {
        if let retryAfterSeconds {
            guard retryAfterSeconds <= Self.maxRetryDelaySeconds else {
                throw GeminiError.rateLimited(retryAfterSeconds: retryAfterSeconds)
            }
            try await sleeper(.seconds(retryAfterSeconds))
        } else {
            try await sleeper(retryPolicy.calculatedDelay(attempt: attempt))
        }
    }
}
