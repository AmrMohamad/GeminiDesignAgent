import Foundation

public struct GeminiInteractionRequest: Codable, Sendable {
    public var model: String
    public var system_instruction: GeminiTextPart?
    public var input: [GeminiInputPart]
    public var response_format: GeminiResponseFormat?
    public var generation_config: GeminiGenerationConfig?

    public init(
        model: String,
        systemInstruction: String? = nil,
        input: [GeminiInputPart],
        responseFormat: GeminiResponseFormat? = nil,
        generationConfig: GeminiGenerationConfig? = nil
    ) {
        self.model = "models/\(model)"
        self.system_instruction = systemInstruction.map { GeminiTextPart(text: $0) }
        self.input = input
        self.response_format = responseFormat
        self.generation_config = generationConfig
    }
}

public struct GeminiTextPart: Codable, Sendable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

public enum GeminiInputPart: Codable, Sendable {
    case text(String)
    case imageData(data: String, mimeType: String)

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text):
            let part = GeminiContentPart(
                text: text,
                inlineData: nil
            )
            try container.encode(part)
        case .imageData(let data, let mimeType):
            let part = GeminiContentPart(
                text: nil,
                inlineData: GeminiInlineData(mimeType: mimeType, data: data)
            )
            try container.encode(part)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let part = try container.decode(GeminiContentPart.self)
        if let text = part.text {
            self = .text(text)
        } else if let inline = part.inlineData {
            self = .imageData(data: inline.data, mimeType: inline.mimeType)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown part")
        }
    }
}

public struct GeminiContentPart: Codable, Sendable {
    public var text: String?
    public var inlineData: GeminiInlineData?

    public init(text: String?, inlineData: GeminiInlineData?) {
        self.text = text
        self.inlineData = inlineData
    }

    enum CodingKeys: String, CodingKey {
        case text
        case inlineData
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(inlineData, forKey: .inlineData)
    }
}

public struct GeminiInlineData: Codable, Sendable {
    public var mimeType: String
    public var data: String

    enum CodingKeys: String, CodingKey {
        case mimeType = "mime_type"
        case data
    }
}

public struct GeminiResponseFormat: Codable, Sendable {
    public var type: String
    public var mime_type: String?
    public var schema: JSONValue?

    public init(type: String, mimeType: String? = nil, schema: JSONValue? = nil) {
        self.type = type
        self.mime_type = mimeType
        self.schema = schema
    }

    public static func jsonSchema(_ schema: JSONValue) -> GeminiResponseFormat {
        GeminiResponseFormat(type: "text", mimeType: "application/json", schema: schema)
    }

    public static let text = GeminiResponseFormat(type: "text")
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
}

public struct GeminiInteractionResponse: Codable, Sendable {
    public var candidates: [GeminiCandidate]?
    public var usageMetadata: GeminiUsageMetadata?
}

public struct GeminiCandidate: Codable, Sendable {
    public var content: GeminiResponseContent?
    public var finishReason: String?
}

public struct GeminiResponseContent: Codable, Sendable {
    public var parts: [GeminiResponsePart]?
}

public struct GeminiResponsePart: Codable, Sendable {
    public var text: String?
}

public struct GeminiUsageMetadata: Codable, Sendable {
    public var promptTokenCount: Int?
    public var candidatesTokenCount: Int?
    public var totalTokenCount: Int?
}

public struct GeminiRawTextResponse: Sendable {
    public var text: String
    public var data: Data
    public var model: String
    public var tokenCount: GeminiUsageMetadata?
}
