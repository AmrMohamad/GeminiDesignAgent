import Foundation

public actor CodeAssistClient {
    private let authorizer: any GeminiRequestAuthorizer
    private let projectID: String?
    private let transport: HTTPTransport
    private let sessionID: String
    private let timeoutSeconds: Int

    public init(
        authorizer: any GeminiRequestAuthorizer,
        projectID: String? = nil,
        transport: HTTPTransport = URLSessionHTTPTransport(),
        timeoutSeconds: Int = 120
    ) {
        self.authorizer = authorizer
        self.projectID = projectID
        self.transport = transport
        self.sessionID = UUID().uuidString.lowercased()
        self.timeoutSeconds = timeoutSeconds
    }

    private var baseURL: URL {
        CodeAssist.baseURL.appendingPathComponent(CodeAssist.apiVersion)
    }

    private func methodURL(_ method: String) -> URL {
        URL(string: "\(baseURL.absoluteString):\(method)") ?? baseURL
    }

    public func loadCodeAssist(
        cloudaicompanionProject: String? = nil,
        mode: String? = nil
    ) async throws -> CodeAssist.LoadCodeAssistResponse {
        let req = CodeAssist.LoadCodeAssistRequest(
            cloudaicompanionProject: cloudaicompanionProject ?? projectID,
            metadata: CodeAssist.ClientMetadata(
                duetProject: cloudaicompanionProject ?? projectID
            ),
            mode: mode
        )
        return try await post("loadCodeAssist", body: req)
    }

    public func onboardUser(
        tierID: String,
        cloudaicompanionProject: String?
    ) async throws -> CodeAssist.LongRunningOperationResponse {
        let req = CodeAssist.OnboardUserRequest(
            tierId: tierID,
            cloudaicompanionProject: cloudaicompanionProject,
            metadata: CodeAssist.ClientMetadata(
                duetProject: cloudaicompanionProject ?? projectID
            )
        )
        return try await post("onboardUser", body: req)
    }

    public func getOperation(name: String) async throws -> CodeAssist.LongRunningOperationResponse {
        let url = URL(string: "\(baseURL.absoluteString)/\(name)") ?? baseURL
        let request = try await authorizedRequest(url: url, method: "GET", body: nil)
        let response = try await transport.execute(request)
        try validateResponse(response)
        return try JSON.decoder.decode(CodeAssist.LongRunningOperationResponse.self, from: response.body)
    }

    public func retrieveUserQuota(project: String) async throws -> CodeAssist.RetrieveUserQuotaResponse {
        let req = CodeAssist.RetrieveUserQuotaRequest(project: project)
        return try await post("retrieveUserQuota", body: req)
    }

    public func listExperiments(project: String) async throws -> CodeAssist.ListExperimentsResponse {
        let request = CodeAssist.ListExperimentsRequest(
            project: project,
            metadata: CodeAssist.ClientMetadata(duetProject: project)
        )
        return try await post("listExperiments", body: request)
    }

    public func generateContent(
        contents: [CodeAssist.GeminiContent],
        model: String,
        systemInstruction: CodeAssist.GeminiContent? = nil,
        generationConfig: CodeAssist.VertexGenerationConfig? = nil,
        userPromptID: String = UUID().uuidString.lowercased(),
        enabledCreditTypes: [String]? = nil,
        signal: (@Sendable () -> Bool)? = nil
    ) async throws -> CodeAssist.GenerateContentResponse {
        var vertexRequest = CodeAssist.VertexGenerateContentRequest(
            contents: contents,
            systemInstruction: systemInstruction,
            generationConfig: generationConfig
        )
        vertexRequest.sessionId = sessionID
        let request = CodeAssist.GenerateContentRequest(
            model: model,
            project: projectID,
            request: vertexRequest,
            userPromptId: userPromptID,
            enabledCreditTypes: enabledCreditTypes
        )
        return try await post("generateContent", body: request, signal: signal)
    }

    /// Parses an SSE response from `streamGenerateContent` into a sequence of
    /// `GenerateContentResponse` chunks. The entire HTTP body is buffered before
    /// parsing — this is not true incremental streaming, but provides the same
    /// chunk-by-chunk yield contract for callers that prefer the streaming API.
    public func generateContentStream(
        contents: [CodeAssist.GeminiContent],
        model: String,
        systemInstruction: CodeAssist.GeminiContent? = nil,
        generationConfig: CodeAssist.VertexGenerationConfig? = nil,
        userPromptID: String = UUID().uuidString.lowercased(),
        enabledCreditTypes: [String]? = nil,
        signal: (@Sendable () -> Bool)? = nil
    ) async throws -> AsyncThrowingStream<CodeAssist.GenerateContentResponse, Error> {
        let bodyData: Data
        do {
            var vertexRequest = CodeAssist.VertexGenerateContentRequest(
                contents: contents,
                systemInstruction: systemInstruction,
                generationConfig: generationConfig
            )
            vertexRequest.sessionId = sessionID
            let request = CodeAssist.GenerateContentRequest(
                model: model,
                project: projectID,
                request: vertexRequest,
                userPromptId: userPromptID,
                enabledCreditTypes: enabledCreditTypes
            )
            bodyData = try JSON.compactEncoder.encode(request)
        }
        let headers = try await authorizer.headers(forceRefresh: false)
        var allHeaders = headers
        allHeaders["Content-Type"] = "application/json"

        var urlComponents = URLComponents(url: methodURL("streamGenerateContent"), resolvingAgainstBaseURL: false)
        urlComponents?.queryItems = [URLQueryItem(name: "alt", value: "sse")]

        guard let url = urlComponents?.url else {
            throw GeminiError.invalidURL
        }

        let httpRequest = GeminiHTTPRequest(
            url: url,
            method: "POST",
            headers: allHeaders,
            body: bodyData,
            timeoutSeconds: timeoutSeconds
        )

        let response = try await transport.execute(httpRequest)
        try validateResponse(response)

        return AsyncThrowingStream { continuation in
            Task {
                let text = String(decoding: response.body, as: UTF8.self)
                let lines = text.components(separatedBy: "\n")
                var buffer: [String] = []

                for line in lines {
                    if signal?() == true {
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                    if line.hasPrefix("data: ") {
                        buffer.append(String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces))
                    } else if line.isEmpty && !buffer.isEmpty {
                        let chunk = buffer.joined(separator: "\n")
                        buffer = []
                        if let data = chunk.data(using: .utf8),
                           let parsed = try? JSON.decoder.decode(CodeAssist.GenerateContentResponse.self, from: data) {
                            continuation.yield(parsed)
                        }
                    }
                }
                if !buffer.isEmpty {
                    let chunk = buffer.joined(separator: "\n")
                    if let data = chunk.data(using: .utf8),
                       let parsed = try? JSON.decoder.decode(CodeAssist.GenerateContentResponse.self, from: data) {
                        continuation.yield(parsed)
                    }
                }
                continuation.finish()
            }
        }
    }

public func extractText(from response: CodeAssist.GenerateContentResponse) -> String? {
        guard let candidates = response.response?.candidates, !candidates.isEmpty else { return nil }
        for candidate in candidates {
            let text = candidate.content?.parts.compactMap { part -> String? in
                if case .text(let text) = part { return text }
                return nil
            }.joined() ?? ""
            if !text.isEmpty {
                return text
            }
        }
        return nil
    }

    public func extractQuota(from response: CodeAssist.GenerateContentResponse) -> (consumed: [CodeAssist.Credits], remaining: [CodeAssist.Credits]) {
        (response.consumedCredits ?? [], response.remainingCredits ?? [])
    }

    public func extractUsage(from response: CodeAssist.GenerateContentResponse) -> GeminiUsageMetadata? {
        guard let meta = response.response?.usageMetadata else { return nil }
        return GeminiUsageMetadata(
            inputTokenCount: meta.promptTokenCount,
            outputTokenCount: meta.candidatesTokenCount,
            thoughtTokenCount: meta.thoughtsTokenCount,
            cachedTokenCount: meta.cachedContentTokenCount,
            totalTokenCount: meta.totalTokenCount
        )
    }

    public func classifyError(_ statusCode: Int, body: Data) -> GeminiError {
        if let envelope = try? JSON.decoder.decode(CodeAssist.CodeAssistErrorEnvelope.self, from: body) {
            let error = envelope.error
            let message = error.message ?? String(decoding: body.prefix(500), as: UTF8.self)

            if statusCode == 429 {
                return classifyQuotaError(message: message, details: error.details)
            }
            if statusCode == 403 {
                if let details = error.details, details.contains(where: { $0.reason == "VALIDATION_REQUIRED" }) {
                    return .billingDisabled("Account validation required: \(message)")
                }
                return .billingDisabled(message)
            }
            if statusCode == 404 {
                return .modelNotFound(message)
            }
            return .httpError(statusCode: statusCode, body: message)
        }
        let message = String(decoding: body.prefix(500), as: UTF8.self)
        if statusCode == 429 {
            return classifyQuotaError(message: message, details: nil)
        }
        return .httpError(statusCode: statusCode, body: message)
    }

    private func classifyQuotaError(message: String, details: [CodeAssist.CodeAssistErrorDetail]?) -> GeminiError {
        let lower = message.lowercased()

        for detail in details ?? [] {
            if detail.reason == "INSUFFICIENT_G1_CREDITS_BALANCE" {
                return .insufficientCredits(message)
            }
            if detail.reason == "QUOTA_EXHAUSTED" {
                if lower.contains("per day") || lower.contains("daily") || lower.contains("perday") {
                    return .quotaExhausted(message)
                }
                if lower.contains("model") {
                    return .modelQuotaExhausted(message)
                }
                return .quotaExhausted(message)
            }
            if detail.reason == "RATE_LIMIT_EXCEEDED" {
                let retryMatch = message.range(of: "retry in (\\d+)s", options: .regularExpression)
                let seconds = retryMatch.flatMap { range in
                    Int(message[range].components(separatedBy: CharacterSet.decimalDigits.inverted).joined())
                }
                return .rateLimited(retryAfterSeconds: seconds)
            }
        }

        if lower.contains("per day") || lower.contains("daily") || lower.contains("perday") {
            return .quotaExhausted(message)
        }
        if lower.contains("per minute") || lower.contains("perminute") || lower.contains("rate limit") {
            return .rateLimited(retryAfterSeconds: nil)
        }
        if lower.contains("model") && (lower.contains("quota") || lower.contains("limit") || lower.contains("exhausted")) {
            return .modelQuotaExhausted(message)
        }
        return .rateLimited(retryAfterSeconds: nil)
    }

    private static let maxServerRetries = 3
    private static let serverRetryDelayMs = 1_000

    private func post<T: Decodable>(
        _ method: String,
        body: some Encodable,
        forceRefresh: Bool = false,
        signal: (@Sendable () -> Bool)? = nil,
        serverRetryAttempt: Int = 0
    ) async throws -> T {
        let bodyData = try JSON.compactEncoder.encode(body)
        let url = methodURL(method)
        let request = try await authorizedRequest(url: url, method: "POST", body: bodyData, forceRefresh: forceRefresh)
        let response = try await transport.execute(request)

        if response.statusCode == 401, !forceRefresh {
            return try await post(method, body: body, forceRefresh: true, signal: signal)
        }

        if (response.statusCode == 429 || response.statusCode == 499 || (500...599).contains(response.statusCode)),
           serverRetryAttempt < Self.maxServerRetries {
            let delayMs = min(Self.serverRetryDelayMs * (1 << serverRetryAttempt), 30_000)
            let jitterMs = Int.random(in: 0...500)
            try await Task.sleep(for: .milliseconds(delayMs + jitterMs))
            return try await post(method, body: body, forceRefresh: forceRefresh, signal: signal, serverRetryAttempt: serverRetryAttempt + 1)
        }

        try validateResponse(response)
        return try JSON.decoder.decode(T.self, from: response.body)
    }

    private func authorizedRequest(
        url: URL,
        method: String,
        body: Data?,
        forceRefresh: Bool = false
    ) async throws -> GeminiHTTPRequest {
        var headers = try await authorizer.headers(forceRefresh: forceRefresh)
        headers["Content-Type"] = "application/json"
        return GeminiHTTPRequest(
            url: url,
            method: method,
            headers: headers,
            body: body ?? Data(),
            timeoutSeconds: timeoutSeconds
        )
    }

    private func validateResponse(_ response: GeminiHTTPResponse) throws {
        guard (200...299).contains(response.statusCode) else {
            throw classifyError(response.statusCode, body: response.body)
        }
    }
}
