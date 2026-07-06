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
        }
    }
}
