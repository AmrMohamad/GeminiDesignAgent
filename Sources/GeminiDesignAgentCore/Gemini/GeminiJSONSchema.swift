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

    public func uppercasingSchemaTypes() -> JSONValue {
        switch self {
        case .array(let values):
            return .array(values.map { $0.uppercasingSchemaTypes() })
        case .object(let object):
            var updated: [String: JSONValue] = [:]
            for (key, value) in object {
                if key == "type", case .string(let type) = value {
                    updated[key] = .string(type.uppercased())
                } else {
                    updated[key] = value.uppercasingSchemaTypes()
                }
            }
            return .object(updated)
        default:
            return self
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
                "items": designElementSchema
            ]),
            "components": .object([
                "type": .string("array"),
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
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object(["type": .string("string")]),
                        "hex": .object(["type": .string("string")]),
                        "role": .object(["type": .string("string")]),
                        "confidence": .object(["type": .string("number")])
                    ]),
                    "required": .array([.string("name"), .string("hex")])
                ])
            ]),
            "typography": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object(["type": .string("string")]),
                        "fontSizePx": .object(["type": .string("integer")]),
                        "fontWeight": .object(["type": .string("string")]),
                        "lineHeightPx": .object(["type": .string("integer")]),
                        "confidence": .object(["type": .string("number")])
                    ])
                ])
            ]),
            "spacingScalePx": .object([
                "type": .string("array"),
                "items": .object(["type": .string("integer")])
            ]),
            "radiiPx": .object([
                "type": .string("array"),
                "items": .object(["type": .string("integer")])
            ]),
            "shadows": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")])
            ])
        ])
    ])

    static let designElementSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "id": .object(["type": .string("string")]),
            "type": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("frame"), .string("section"), .string("navbar"),
                    .string("text"), .string("button"), .string("input"),
                    .string("image"), .string("icon"), .string("card"),
                    .string("list"), .string("divider"), .string("unknown")
                ])
            ]),
            "label": .object(["type": .string("string")]),
            "bbox1000": .object([
                "type": .string("object"),
                "properties": .object([
                    "ymin": .object(["type": .string("integer")]),
                    "xmin": .object(["type": .string("integer")]),
                    "ymax": .object(["type": .string("integer")]),
                    "xmax": .object(["type": .string("integer")]),
                    "confidence": .object(["type": .string("number")])
                ]),
                "required": .array([.string("ymin"), .string("xmin"), .string("ymax"), .string("xmax")])
            ]),
            "visibleText": .object(["type": .string("string")]),
            "colorsHex": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")])
            ]),
            "typography": .object([
                "type": .string("object"),
                "properties": .object([
                    "fontSizePx": .object(["type": .string("integer")]),
                    "fontWeight": .object(["type": .string("string")]),
                    "lineHeightPx": .object(["type": .string("integer")]),
                    "letterSpacingPx": .object(["type": .string("number")]),
                    "alignment": .object(["type": .string("string")]),
                    "colorHex": .object(["type": .string("string")]),
                    "confidence": .object(["type": .string("number")])
                ])
            ]),
            "spacing": .object([
                "type": .string("object"),
                "properties": .object([
                    "top": .object(["type": .string("integer")]),
                    "right": .object(["type": .string("integer")]),
                    "bottom": .object(["type": .string("integer")]),
                    "left": .object(["type": .string("integer")]),
                    "vertical": .object(["type": .string("integer")]),
                    "horizontal": .object(["type": .string("integer")]),
                    "confidence": .object(["type": .string("number")])
                ])
            ]),
            "borderRadiusPx": .object(["type": .string("integer")]),
            "shadow": .object(["type": .string("string")]),
            "cssHints": .object([
                "type": .string("object"),
                "additionalProperties": .object(["type": .string("string")])
            ]),
            "children": .object([
                "type": .string("array"),
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
            "id": .object(["type": .string("string")]),
            "name": .object(["type": .string("string")]),
            "type": .object(["type": .string("string")]),
            "description": .object(["type": .string("string")]),
            "elementIds": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")])
            ]),
            "styleHints": .object([
                "type": .string("object"),
                "additionalProperties": .object(["type": .string("string")])
            ]),
            "confidence": .object(["type": .string("number")])
        ])
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
            "priority": .object(["type": .string("integer")]),
            "sceneName": .object(["type": .string("string")]),
            "componentName": .object(["type": .string("string")]),
            "content": .object(["type": .string("string")]),
            "tags": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")])
            ]),
            "confidence": .object(["type": .string("number")])
        ]),
        "required": .array([.string("type"), .string("scope"), .string("priority"), .string("content"), .string("tags")])
    ])
}
