import Foundation

/// Applies an explicit, same-account model chain. It never changes an OAuth
/// profile, API key, project, or account; it only retries a request against a
/// configured fallback after a terminal, model-specific failure.
public actor ModelFallbackAnalyzer: GeminiDesignAnalyzing {
    private let base: any GeminiDesignAnalyzing
    private let fallbacks: [String]
    private var stickyModel: String?
    private var lastAttemptedModels: [String] = []

    public init(base: any GeminiDesignAnalyzing, fallbacks: [String]) {
        self.base = base
        self.fallbacks = Self.normalized(fallbacks)
    }

    public func analyzeImage(
        model: String,
        imageURL: URL,
        mimeType: String,
        systemInstruction: String,
        userPrompt: String,
        responseSchema: JSONValue
    ) async throws -> GeminiRawTextResponse {
        let base = self.base
        return try await attempt(models: candidates(preferred: model)) { candidate in
            try await base.analyzeImage(
                model: candidate,
                imageURL: imageURL,
                mimeType: mimeType,
                systemInstruction: systemInstruction,
                userPrompt: userPrompt,
                responseSchema: responseSchema
            )
        }
    }

    public func analyzeText(
        model: String,
        systemInstruction: String,
        userPrompt: String,
        responseSchema: JSONValue
    ) async throws -> GeminiRawTextResponse {
        let base = self.base
        return try await attempt(models: candidates(preferred: model)) { candidate in
            try await base.analyzeText(
                model: candidate,
                systemInstruction: systemInstruction,
                userPrompt: userPrompt,
                responseSchema: responseSchema
            )
        }
    }

    public func attemptedModels() -> [String] {
        return lastAttemptedModels
    }

    private func attempt(
        models: [String],
        operation: @escaping @Sendable (String) async throws -> GeminiRawTextResponse
    ) async throws -> GeminiRawTextResponse {
        var lastError: Error?
        lastAttemptedModels = []
        for (index, candidate) in models.enumerated() {
            lastAttemptedModels.append(candidate)
            do {
                var response = try await operation(candidate)
                response.model = candidate
                stickyModel = candidate
                return response
            } catch {
                lastError = error
                guard index < models.count - 1, Self.canFallback(after: error) else { throw error }
            }
        }
        throw lastError ?? GeminiError.unexpectedResponse("No model candidate was available")
    }

    private func candidates(preferred: String) -> [String] {
        let sticky = stickyModel
        return Self.normalized([sticky, preferred].compactMap { $0 } + fallbacks)
    }

    private static func canFallback(after error: Error) -> Bool {
        if let runFailure = error as? AnalyzeRunFailure {
            return canFallback(after: runFailure.underlying)
        }
        guard let geminiError = error as? GeminiError else { return false }
        switch geminiError {
        case .modelNotFound, .modelQuotaExhausted:
            return true
        default:
            return false
        }
    }

    private static func normalized(_ models: [String]) -> [String] {
        var seen = Set<String>()
        return models.compactMap { value in
            let model = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty, seen.insert(model).inserted else { return nil }
            return model
        }
    }
}
