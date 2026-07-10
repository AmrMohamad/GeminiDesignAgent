import Foundation

public enum GeminiError: Error, LocalizedError {
    case invalidURL
    case httpError(statusCode: Int, body: String)
    case invalidJSON(String)
    case rateLimited(retryAfterSeconds: Int?)
    case timeout
    case networkUnavailable(String)
    case dnsFailure(String)
    case connectionFailed(String)
    case apiKeyMissing
    case unexpectedResponse(String)
    case imageTooLarge(Int)
    case requestTooLarge(Int)
    case contentBlocked(String)
    case noCandidates(String)
    case noTextOutput(String)
    case interactionIncomplete(String)
    case interactionFailed(String)
    case interactionCancelled
    case invalidSynchronousInteractionState
    case unsupportedInteractionState(String)
    case quotaExhausted(String)
    case modelNotFound(String)
    case billingDisabled(String)
    case invalidAPIKey(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid Gemini API URL"
        case .httpError(let code, let body): return "HTTP \(code): \(body)"
        case .invalidJSON(let msg): return "Invalid Gemini JSON: \(msg)"
        case .rateLimited(let retryAfterSeconds):
            if let retryAfterSeconds {
                return "Gemini rate limited. Retry after \(retryAfterSeconds) seconds"
            }
            return "Gemini rate limited"
        case .timeout: return "Gemini request timed out"
        case .networkUnavailable(let details): return "Gemini network unavailable: \(details)"
        case .dnsFailure(let details): return "Gemini DNS failure: \(details)"
        case .connectionFailed(let details): return "Gemini connection failed: \(details)"
        case .apiKeyMissing: return "GEMINI_API_KEY not set"
        case .unexpectedResponse(let msg): return "Unexpected response: \(msg)"
        case .imageTooLarge(let size): return "Image too large for inline upload: \(size) bytes"
        case .requestTooLarge(let size): return "Gemini inline request too large: \(size) bytes (limit is 20971520 bytes)"
        case .contentBlocked(let reason): return "Gemini content blocked: \(reason)"
        case .noCandidates(let msg): return "Gemini returned no candidates: \(msg)"
        case .noTextOutput(let msg): return "Gemini returned no text output: \(msg)"
        case .interactionIncomplete(let msg): return "Gemini interaction returned incomplete output: \(msg)"
        case .interactionFailed(let msg): return "Gemini interaction failed: \(msg)"
        case .interactionCancelled: return "Gemini interaction was cancelled"
        case .invalidSynchronousInteractionState: return "Gemini interaction remained in progress in a synchronous response"
        case .unsupportedInteractionState(let state): return "Gemini interaction returned unsupported state: \(state)"
        case .quotaExhausted(let msg): return "Gemini quota exhausted: \(msg)"
        case .modelNotFound(let msg): return "Gemini model not found: \(msg)"
        case .billingDisabled(let msg): return "Gemini billing disabled or unavailable: \(msg)"
        case .invalidAPIKey(let msg): return "Gemini API key is invalid: \(msg)"
        }
    }
}
