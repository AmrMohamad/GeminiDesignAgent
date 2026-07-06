import Foundation

public enum DesignElementType: String, Codable, Sendable {
    case frame
    case section
    case navbar
    case text
    case button
    case input
    case image
    case icon
    case card
    case list
    case divider
    case unknown
}

public struct TypographyGuess: Codable, Sendable {
    public var fontSizePx: Int?
    public var fontWeight: String?
    public var lineHeightPx: Int?
    public var letterSpacingPx: Double?
    public var alignment: String?
    public var colorHex: String?
    public var confidence: Double
}

public struct SpacingGuess: Codable, Sendable {
    public var top: Int?
    public var right: Int?
    public var bottom: Int?
    public var left: Int?
    public var vertical: Int?
    public var horizontal: Int?
    public var confidence: Double
}

public struct DesignElement: Codable, Sendable, Identifiable {
    public var id: String
    public var type: DesignElementType
    public var label: String

    public var bbox1000: BBox1000
    public var bboxPx: BBoxPx?

    public var visibleText: String?
    public var colorsHex: [String]
    public var typography: TypographyGuess?
    public var spacing: SpacingGuess?

    public var borderRadiusPx: Int?
    public var shadow: String?
    public var cssHints: [String: String]
    public var children: [String]
    public var implementationNotes: [String]

    public init(
        id: String,
        type: DesignElementType,
        label: String,
        bbox1000: BBox1000,
        bboxPx: BBoxPx? = nil,
        visibleText: String? = nil,
        colorsHex: [String] = [],
        typography: TypographyGuess? = nil,
        spacing: SpacingGuess? = nil,
        borderRadiusPx: Int? = nil,
        shadow: String? = nil,
        cssHints: [String: String] = [:],
        children: [String] = [],
        implementationNotes: [String] = []
    ) {
        self.id = id
        self.type = type
        self.label = label
        self.bbox1000 = bbox1000
        self.bboxPx = bboxPx
        self.visibleText = visibleText
        self.colorsHex = colorsHex
        self.typography = typography
        self.spacing = spacing
        self.borderRadiusPx = borderRadiusPx
        self.shadow = shadow
        self.cssHints = cssHints
        self.children = children
        self.implementationNotes = implementationNotes
    }
}
