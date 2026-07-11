import Foundation

public indirect enum JSONValue: Codable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let i = try? container.decode(Int.self) { self = .int(i) }
        else if let d = try? container.decode(Double.self) { self = .double(d) }
        else if let s = try? container.decode(String.self) { self = .string(s) }
        else if let a = try? container.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? container.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown JSON value") }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }

}

public enum GeminiJSONSchema {
    public static let designAnalysis: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "schemaVersion": .object(["type": .string("string")]),
            "summary": .object(["type": .string("string")]),
            "tokens": designTokensSchema,
            "elements": .object([
                "type": .string("array"),
                "maxItems": .int(1_000),
                "items": designElementSchema
            ]),
            "components": .object([
                "type": .string("array"),
                "maxItems": .int(500),
                "items": componentCandidateSchema
            ]),
            "implementation": .object([
                "type": .string("object"),
                "properties": .object([
                    "framework": .object(["type": .string("string")]),
                    "layoutStrategy": .object(["type": .string("string")]),
                    "cssFramework": .object(["type": .string("string")]),
                    "notes": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")])
                    ])
                ])
            ]),
            "accessibility": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")])
            ]),
            "warnings": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")])
            ]),
            "memoryWrites": .object([
                "type": .string("array"),
                "items": memoryWriteSchema
            ])
        ]),
        "required": .array([
            .string("schemaVersion"),
            .string("summary"),
            .string("tokens"),
            .string("elements"),
            .string("memoryWrites")
        ])
    ])

    static let designTokensSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "colors": .object([
                "type": .string("array"),
                "maxItems": .int(500),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object(["type": .string("string")]),
                        "hex": .object(["type": .string("string"), "pattern": .string("^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$")]),
                        "role": .object(["type": .string("string")]),
                        "confidence": .object(["type": .string("number"), "minimum": .int(0), "maximum": .int(1)])
                    ]),
                    "required": .array([.string("name"), .string("hex")])
                ])
            ]),
            "typography": .object([
                "type": .string("array"),
                "maxItems": .int(500),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object(["type": .string("string")]),
                        "fontSizePx": .object(["type": .string("integer"), "minimum": .int(1), "maximum": .int(512)]),
                        "fontWeight": .object(["type": .string("string")]),
                        "lineHeightPx": .object(["type": .string("integer"), "minimum": .int(1), "maximum": .int(1024)]),
                        "confidence": .object(["type": .string("number"), "minimum": .int(0), "maximum": .int(1)])
                    ]),
                    "required": .array([.string("name"), .string("fontSizePx")])
                ])
            ]),
            "spacingScalePx": .object([
                "type": .string("array"),
                "maxItems": .int(500),
                "items": .object(["type": .string("integer"), "minimum": .int(0), "maximum": .int(4096)])
            ]),
            "radiiPx": .object([
                "type": .string("array"),
                "maxItems": .int(500),
                "items": .object(["type": .string("integer"), "minimum": .int(0), "maximum": .int(4096)])
            ]),
            "shadows": .object([
                "type": .string("array"),
                "maxItems": .int(500),
                "items": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(1000)])
            ])
        ])
    ])

    static let designElementSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "id": .object(["type": .string("string"), "minLength": .int(1)]),
            "type": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("frame"), .string("section"), .string("navbar"),
                    .string("text"), .string("button"), .string("input"),
                    .string("image"), .string("icon"), .string("card"),
                    .string("list"), .string("divider"), .string("unknown")
                ])
            ]),
            "label": .object(["type": .string("string"), "maxLength": .int(1000)]),
            "bbox1000": .object([
                "type": .string("object"),
                "properties": .object([
                    "ymin": .object(["type": .string("integer"), "minimum": .int(0), "maximum": .int(1000)]),
                    "xmin": .object(["type": .string("integer"), "minimum": .int(0), "maximum": .int(1000)]),
                    "ymax": .object(["type": .string("integer"), "minimum": .int(0), "maximum": .int(1000)]),
                    "xmax": .object(["type": .string("integer"), "minimum": .int(0), "maximum": .int(1000)]),
                    "confidence": .object(["type": .string("number"), "minimum": .int(0), "maximum": .int(1)])
                ]),
                "required": .array([.string("ymin"), .string("xmin"), .string("ymax"), .string("xmax")])
            ]),
            "visibleText": .object(["type": .string("string"), "maxLength": .int(10000)]),
            "colorsHex": .object([
                "type": .string("array"),
                "maxItems": .int(500),
                "items": .object(["type": .string("string"), "pattern": .string("^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$")])
            ]),
            "typography": .object([
                "type": .string("object"),
                "properties": .object([
                    "fontSizePx": .object(["type": .string("integer"), "minimum": .int(1), "maximum": .int(512)]),
                    "fontWeight": .object(["type": .string("string")]),
                    "lineHeightPx": .object(["type": .string("integer"), "minimum": .int(1), "maximum": .int(1024)]),
                    "letterSpacingPx": .object(["type": .string("number"), "minimum": .int(-64), "maximum": .int(64)]),
                    "alignment": .object(["type": .string("string")]),
                    "colorHex": .object(["type": .string("string")]),
                    "confidence": .object(["type": .string("number"), "minimum": .int(0), "maximum": .int(1)])
                ])
            ]),
            "spacing": .object([
                "type": .string("object"),
                "properties": .object([
                    "top": .object(["type": .string("integer"), "minimum": .int(0), "maximum": .int(4096)]),
                    "right": .object(["type": .string("integer"), "minimum": .int(0), "maximum": .int(4096)]),
                    "bottom": .object(["type": .string("integer"), "minimum": .int(0), "maximum": .int(4096)]),
                    "left": .object(["type": .string("integer"), "minimum": .int(0), "maximum": .int(4096)]),
                    "vertical": .object(["type": .string("integer"), "minimum": .int(0), "maximum": .int(4096)]),
                    "horizontal": .object(["type": .string("integer"), "minimum": .int(0), "maximum": .int(4096)]),
                    "confidence": .object(["type": .string("number"), "minimum": .int(0), "maximum": .int(1)])
                ])
            ]),
            "borderRadiusPx": .object(["type": .string("integer"), "minimum": .int(0), "maximum": .int(4096)]),
            "shadow": .object(["type": .string("string")]),
            "cssHints": .object([
                "type": .string("object"),
                "additionalProperties": .object(["type": .string("string")])
            ]),
            "children": .object([
                "type": .string("array"),
                "maxItems": .int(1000),
                "items": .object(["type": .string("string")])
            ]),
            "implementationNotes": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")])
            ])
        ]),
        "required": .array([.string("id"), .string("type"), .string("label"), .string("bbox1000")])
    ])

    static let componentCandidateSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "id": .object(["type": .string("string"), "minLength": .int(1)]),
            "name": .object(["type": .string("string"), "maxLength": .int(1000)]),
            "type": .object(["type": .string("string")]),
            "description": .object(["type": .string("string"), "maxLength": .int(10000)]),
            "elementIds": .object([
                "type": .string("array"),
                "maxItems": .int(1000),
                "items": .object(["type": .string("string")])
            ]),
            "styleHints": .object([
                "type": .string("object"),
                "additionalProperties": .object(["type": .string("string")])
            ]),
            "confidence": .object(["type": .string("number"), "minimum": .int(0), "maximum": .int(1)])
        ]),
        "required": .array([.string("id"), .string("name")])
    ])

    static let memoryWriteSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "type": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("projectStyle"), .string("designToken"), .string("component"),
                    .string("layoutRule"), .string("spacingRule"), .string("typographyRule"),
                    .string("screenFact"), .string("implementationInstruction"),
                    .string("userPreference"), .string("warning")
                ])
            ]),
            "scope": .object([
                "type": .string("string"),
                "enum": .array([.string("global"), .string("screen"), .string("component"), .string("session")])
            ]),
            "priority": .object(["type": .string("integer"), "minimum": .int(0), "maximum": .int(100)]),
            "sceneName": .object(["type": .string("string")]),
            "componentName": .object(["type": .string("string")]),
            "content": .object(["type": .string("string")]),
            "tags": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")])
            ]),
            "confidence": .object(["type": .string("number"), "minimum": .int(0), "maximum": .int(1)])
        ]),
        "required": .array([.string("type"), .string("scope"), .string("priority"), .string("content"), .string("tags")])
    ])
}
