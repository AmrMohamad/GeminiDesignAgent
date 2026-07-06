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
}

public struct DesignTokens: Codable, Sendable {
    public var colors: [NamedColorToken]
    public var typography: [TypographyToken]
    public var spacingScalePx: [Int]
    public var radiiPx: [Int]
    public var shadows: [String]

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
}
