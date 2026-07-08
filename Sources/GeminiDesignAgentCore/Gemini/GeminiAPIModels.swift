import Foundation

public struct GeminiGenerateContentRequest: Codable, Sendable {
    public var contents: [GeminiContent]
    public var generationConfig: GeminiGenerationConfig?

    public init(
        contents: [GeminiContent],
        generationConfig: GeminiGenerationConfig? = nil
    ) {
        self.contents = contents
        self.generationConfig = generationConfig
    }

    enum CodingKeys: String, CodingKey {
        case contents
        case generationConfig
    }
}

public struct GeminiTextPart: Codable, Sendable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

public struct GeminiContent: Codable, Sendable {
    public var parts: [GeminiContentPart]

    public init(parts: [GeminiContentPart]) {
        self.parts = parts
    }
}

public enum GeminiInputPart: Codable, Sendable {
    case text(String)
    case imageData(data: String, mimeType: String)

    public var contentPart: GeminiContentPart {
        switch self {
        case .text(let text):
            return GeminiContentPart(text: text, inlineData: nil)
        case .imageData(let data, let mimeType):
            return GeminiContentPart(text: nil, inlineData: GeminiInlineData(mimeType: mimeType, data: data))
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

    public init(mimeType: String, data: String) {
        self.mimeType = mimeType
        self.data = data
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

    public static let text = GeminiResponseFormat(type: "text")
}

public struct GeminiGenerationConfig: Codable, Sendable {
    public var temperature: Double?
    public var topP: Double?
    public var topK: Int?
    public var candidateCount: Int?
    public var maxOutputTokens: Int?
    public var responseFormat: [GeminiResponseFormat]?

    public init(
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        candidateCount: Int? = nil,
        maxOutputTokens: Int? = nil,
        responseFormat: [GeminiResponseFormat]? = nil
    ) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.candidateCount = candidateCount
        self.maxOutputTokens = maxOutputTokens
        self.responseFormat = responseFormat
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
