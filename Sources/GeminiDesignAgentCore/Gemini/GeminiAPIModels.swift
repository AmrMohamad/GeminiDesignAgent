import Foundation

public struct GeminiInteractionRequest: Codable, Sendable {
    public var model: String
    public var systemInstruction: String
    public var input: [GeminiInteractionInput]
    public var responseFormat: GeminiResponseFormat
    public var generationConfig: GeminiGenerationConfig?
    public var store: Bool

    public init(
        model: String,
        systemInstruction: String,
        input: [GeminiInteractionInput],
        responseFormat: GeminiResponseFormat,
        generationConfig: GeminiGenerationConfig? = nil,
        store: Bool = false
    ) {
        self.model = model
        self.systemInstruction = systemInstruction
        self.input = input
        self.responseFormat = responseFormat
        self.generationConfig = generationConfig
        self.store = store
    }

    enum CodingKeys: String, CodingKey {
        case model
        case systemInstruction = "system_instruction"
        case input
        case responseFormat = "response_format"
        case generationConfig = "generation_config"
        case store
    }
}

public enum GeminiInteractionInput: Codable, Sendable {
    case text(String)
    case image(data: String, mimeType: String)

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case data
        case mimeType = "mime_type"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let data, let mimeType):
            try container.encode("image", forKey: .type)
            try container.encode(data, forKey: .data)
            try container.encode(mimeType, forKey: .mimeType)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case "image":
            self = .image(
                data: try container.decode(String.self, forKey: .data),
                mimeType: try container.decode(String.self, forKey: .mimeType)
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unsupported Gemini input type: \(type)")
        }
    }
}

public struct GeminiResponseFormat: Codable, Sendable {
    public var type: String
    public var mimeType: String?
    public var schema: JSONValue?

    public init(type: String, mimeType: String? = nil, schema: JSONValue? = nil) {
        self.type = type
        self.mimeType = mimeType
        self.schema = schema
    }

    public static func jsonSchema(_ schema: JSONValue) -> GeminiResponseFormat {
        GeminiResponseFormat(type: "text", mimeType: "application/json", schema: schema)
    }

    enum CodingKeys: String, CodingKey {
        case type
        case mimeType = "mime_type"
        case schema
    }
}

public struct GeminiGenerationConfig: Codable, Sendable {
    public var temperature: Double?
    public var topP: Double?
    public var topK: Int?
    public var candidateCount: Int?
    public var maxOutputTokens: Int?

    public init(
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        candidateCount: Int? = nil,
        maxOutputTokens: Int? = nil
    ) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.candidateCount = candidateCount
        self.maxOutputTokens = maxOutputTokens
    }

    enum CodingKeys: String, CodingKey {
        case temperature
        case topP = "top_p"
        case topK = "top_k"
        case candidateCount = "candidate_count"
        case maxOutputTokens = "max_output_tokens"
    }
}

public enum GeminiInteractionStatus: Sendable, Equatable, Codable {
    case completed
    case incomplete
    case failed
    case cancelled
    case requiresAction
    case inProgress
    case unknown(String)

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "completed": self = .completed
        case "incomplete": self = .incomplete
        case "failed": self = .failed
        case "cancelled": self = .cancelled
        case "requires_action": self = .requiresAction
        case "in_progress": self = .inProgress
        default: self = .unknown(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var rawValue: String {
        switch self {
        case .completed: "completed"
        case .incomplete: "incomplete"
        case .failed: "failed"
        case .cancelled: "cancelled"
        case .requiresAction: "requires_action"
        case .inProgress: "in_progress"
        case .unknown(let value): value
        }
    }
}

public struct GeminiInteractionResponse: Codable, Sendable {
    public var status: GeminiInteractionStatus
    public var steps: [GeminiInteractionStep]?
    public var usage: GeminiUsageMetadata?

    enum CodingKeys: String, CodingKey {
        case status
        case steps
        case usage
    }
}

public struct GeminiInteractionStep: Codable, Sendable {
    public var type: String
    public var status: String?
    public var content: [GeminiInteractionContent]?

    enum CodingKeys: String, CodingKey {
        case type
        case status
        case content
    }
}

public struct GeminiInteractionContent: Codable, Sendable {
    public var type: String?
    public var text: String?
}

public struct GeminiUsageMetadata: Codable, Sendable {
    public var inputTokenCount: Int?
    public var outputTokenCount: Int?
    public var totalTokenCount: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokenCount = "total_input_tokens"
        case outputTokenCount = "total_output_tokens"
        case totalTokenCount = "total_tokens"
    }
}

public struct GeminiRawTextResponse: Sendable {
    public var text: String
    public var data: Data
    public var model: String
    public var usage: GeminiUsageMetadata?
}

struct GeminiAPIErrorEnvelope: Decodable, Sendable {
    var error: GeminiAPIErrorPayload
}

struct GeminiAPIErrorPayload: Decodable, Sendable {
    var code: JSONValue?
    var message: String?
    var status: String?

    var explicitCode: String? {
        guard case .string(let value) = code else { return nil }
        return value
    }
}
