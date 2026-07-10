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

    enum CodingKeys: String, CodingKey {
        case fontSizePx
        case fontWeight
        case lineHeightPx
        case letterSpacingPx
        case alignment
        case colorHex
        case confidence
    }

    public init(
        fontSizePx: Int? = nil,
        fontWeight: String? = nil,
        lineHeightPx: Int? = nil,
        letterSpacingPx: Double? = nil,
        alignment: String? = nil,
        colorHex: String? = nil,
        confidence: Double = 1.0
    ) {
        self.fontSizePx = fontSizePx
        self.fontWeight = fontWeight
        self.lineHeightPx = lineHeightPx
        self.letterSpacingPx = letterSpacingPx
        self.alignment = alignment
        self.colorHex = colorHex
        self.confidence = confidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.fontSizePx = try container.decodeIfPresent(Int.self, forKey: .fontSizePx)
        self.fontWeight = try container.decodeIfPresent(String.self, forKey: .fontWeight)
        self.lineHeightPx = try container.decodeIfPresent(Int.self, forKey: .lineHeightPx)
        self.letterSpacingPx = try container.decodeIfPresent(Double.self, forKey: .letterSpacingPx)
        self.alignment = try container.decodeIfPresent(String.self, forKey: .alignment)
        self.colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex)
        self.confidence = try container.decodeGeneratedConfidence(forKey: .confidence)
    }
}

public struct SpacingGuess: Codable, Sendable {
    public var top: Int?
    public var right: Int?
    public var bottom: Int?
    public var left: Int?
    public var vertical: Int?
    public var horizontal: Int?
    public var confidence: Double

    enum CodingKeys: String, CodingKey {
        case top
        case right
        case bottom
        case left
        case vertical
        case horizontal
        case confidence
    }

    public init(
        top: Int? = nil,
        right: Int? = nil,
        bottom: Int? = nil,
        left: Int? = nil,
        vertical: Int? = nil,
        horizontal: Int? = nil,
        confidence: Double = 1.0
    ) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
        self.vertical = vertical
        self.horizontal = horizontal
        self.confidence = confidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.top = try container.decodeIfPresent(Int.self, forKey: .top)
        self.right = try container.decodeIfPresent(Int.self, forKey: .right)
        self.bottom = try container.decodeIfPresent(Int.self, forKey: .bottom)
        self.left = try container.decodeIfPresent(Int.self, forKey: .left)
        self.vertical = try container.decodeIfPresent(Int.self, forKey: .vertical)
        self.horizontal = try container.decodeIfPresent(Int.self, forKey: .horizontal)
        self.confidence = try container.decodeGeneratedConfidence(forKey: .confidence)
    }
}

public struct DesignElement: Codable, Sendable, Identifiable {
    public var id: String
    public var type: DesignElementType
    public var label: String

    public var bbox1000: BBox1000
    public var bboxPx: BBoxPx?
    public var bboxCss: BBoxPx?

    public var visibleText: String?
    public var colorsHex: [String]
    public var typography: TypographyGuess?
    public var spacing: SpacingGuess?

    public var borderRadiusPx: Int?
    public var shadow: String?
    public var cssHints: [String: String]
    public var children: [String]
    public var implementationNotes: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case label
        case bbox1000
        case bboxPx
        case bboxCss
        case visibleText
        case colorsHex
        case typography
        case spacing
        case borderRadiusPx
        case shadow
        case cssHints
        case children
        case implementationNotes
    }

    public init(
        id: String,
        type: DesignElementType,
        label: String,
        bbox1000: BBox1000,
        bboxPx: BBoxPx? = nil,
        bboxCss: BBoxPx? = nil,
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
        self.bboxCss = bboxCss
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.type = try container.decode(DesignElementType.self, forKey: .type)
        self.label = try container.decode(String.self, forKey: .label)
        self.bbox1000 = try container.decode(BBox1000.self, forKey: .bbox1000)
        self.bboxPx = try container.decodeIfPresent(BBoxPx.self, forKey: .bboxPx)
        self.bboxCss = try container.decodeIfPresent(BBoxPx.self, forKey: .bboxCss)
        self.visibleText = try container.decodeIfPresent(String.self, forKey: .visibleText)
        self.colorsHex = try container.decodeIfPresent([String].self, forKey: .colorsHex) ?? []
        self.typography = try container.decodeIfPresent(TypographyGuess.self, forKey: .typography)
        self.spacing = try container.decodeIfPresent(SpacingGuess.self, forKey: .spacing)
        self.borderRadiusPx = try container.decodeIfPresent(Int.self, forKey: .borderRadiusPx)
        self.shadow = try container.decodeIfPresent(String.self, forKey: .shadow)
        self.cssHints = try container.decodeIfPresent([String: String].self, forKey: .cssHints) ?? [:]
        self.children = try container.decodeIfPresent([String].self, forKey: .children) ?? []
        self.implementationNotes = try container.decodeIfPresent([String].self, forKey: .implementationNotes) ?? []
    }
}
