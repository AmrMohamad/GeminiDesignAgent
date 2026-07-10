import Foundation

public struct NamedColorToken: Codable, Sendable {
    public var name: String
    public var hex: String
    public var role: String?
    public var confidence: Double

    public init(name: String, hex: String, role: String? = nil, confidence: Double = 1.0) {
        self.name = name
        self.hex = hex
        self.role = role
        self.confidence = confidence
    }

    enum CodingKeys: String, CodingKey {
        case name
        case hex
        case role
        case confidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.hex = try container.decode(String.self, forKey: .hex)
        self.role = try container.decodeIfPresent(String.self, forKey: .role)
        self.confidence = try container.decodeGeneratedConfidence(forKey: .confidence)
    }
}

public struct TypographyToken: Codable, Sendable {
    public var name: String
    public var fontSizePx: Int
    public var fontWeight: String?
    public var lineHeightPx: Int?
    public var confidence: Double

    public init(name: String, fontSizePx: Int, fontWeight: String? = nil, lineHeightPx: Int? = nil, confidence: Double = 1.0) {
        self.name = name
        self.fontSizePx = fontSizePx
        self.fontWeight = fontWeight
        self.lineHeightPx = lineHeightPx
        self.confidence = confidence
    }

    enum CodingKeys: String, CodingKey {
        case name
        case fontSizePx
        case fontWeight
        case lineHeightPx
        case confidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.fontSizePx = try container.decode(Int.self, forKey: .fontSizePx)
        self.fontWeight = try container.decodeIfPresent(String.self, forKey: .fontWeight)
        self.lineHeightPx = try container.decodeIfPresent(Int.self, forKey: .lineHeightPx)
        self.confidence = try container.decodeGeneratedConfidence(forKey: .confidence)
    }
}

public struct DesignTokens: Codable, Sendable {
    public var colors: [NamedColorToken]
    public var typography: [TypographyToken]
    public var spacingScalePx: [Int]
    public var radiiPx: [Int]
    public var shadows: [String]

    enum CodingKeys: String, CodingKey {
        case colors
        case typography
        case spacingScalePx
        case radiiPx
        case shadows
    }

    public init(
        colors: [NamedColorToken] = [],
        typography: [TypographyToken] = [],
        spacingScalePx: [Int] = [],
        radiiPx: [Int] = [],
        shadows: [String] = []
    ) {
        self.colors = colors
        self.typography = typography
        self.spacingScalePx = spacingScalePx
        self.radiiPx = radiiPx
        self.shadows = shadows
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.colors = try container.decodeIfPresent([NamedColorToken].self, forKey: .colors) ?? []
        self.typography = try container.decodeIfPresent([TypographyToken].self, forKey: .typography) ?? []
        self.spacingScalePx = try container.decodeIfPresent([Int].self, forKey: .spacingScalePx) ?? []
        self.radiiPx = try container.decodeIfPresent([Int].self, forKey: .radiiPx) ?? []
        self.shadows = try container.decodeIfPresent([String].self, forKey: .shadows) ?? []
    }
}
