import Foundation

public enum GeminiError: Error, LocalizedError {
    case invalidURL
    case httpError(statusCode: Int, body: String)
    case invalidJSON(String)
    case rateLimited
    case timeout
    case apiKeyMissing
    case unexpectedResponse(String)
    case imageTooLarge(Int)
    case contentBlocked(String)
    case noCandidates(String)
    case maxTokensTruncated(String)
    case quotaExhausted(String)
    case modelNotFound(String)
    case billingDisabled(String)
    case invalidAPIKey(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid Gemini API URL"
        case .httpError(let code, let body): "HTTP \(code): \(body)"
        case .invalidJSON(let msg): "Invalid Gemini JSON: \(msg)"
        case .rateLimited: "Gemini rate limited"
        case .timeout: "Gemini request timed out"
        case .apiKeyMissing: "GEMINI_API_KEY not set"
        case .unexpectedResponse(let msg): "Unexpected response: \(msg)"
        case .imageTooLarge(let size): "Image too large for inline upload: \(size) bytes"
        case .contentBlocked(let reason): "Gemini content blocked: \(reason)"
        case .noCandidates(let msg): "Gemini returned no candidates: \(msg)"
        case .maxTokensTruncated(let msg): "Gemini output was truncated by max tokens: \(msg)"
        case .quotaExhausted(let msg): "Gemini quota exhausted: \(msg)"
        case .modelNotFound(let msg): "Gemini model not found: \(msg)"
        case .billingDisabled(let msg): "Gemini billing disabled or unavailable: \(msg)"
        case .invalidAPIKey(let msg): "Gemini API key is invalid: \(msg)"
        }
    }
}
