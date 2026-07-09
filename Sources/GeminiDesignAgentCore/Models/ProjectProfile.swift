import Foundation

public struct ComponentCandidate: Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var type: String
    public var description: String
    public var elementIds: [String]
    public var styleHints: [String: String]
    public var confidence: Double

    public init(
        id: String,
        name: String,
        type: String = "component",
        description: String = "",
        elementIds: [String] = [],
        styleHints: [String: String] = [:],
        confidence: Double = 1.0
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.description = description
        self.elementIds = elementIds
        self.styleHints = styleHints
        self.confidence = confidence
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case type
        case description
        case elementIds
        case styleHints
        case confidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "component"
        self.description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.elementIds = try container.decodeIfPresent([String].self, forKey: .elementIds) ?? []
        self.styleHints = try container.decodeIfPresent([String: String].self, forKey: .styleHints) ?? [:]
        self.confidence = try container.decodeGeneratedConfidence(forKey: .confidence)
    }
}

public struct ComponentProfile: Codable, Sendable {
    public var name: String
    public var type: String
    public var description: String
    public var styleHints: [String: String]
    public var confidence: Double

    public init(
        name: String,
        type: String = "component",
        description: String = "",
        styleHints: [String: String] = [:],
        confidence: Double = 1.0
    ) {
        self.name = name
        self.type = type
        self.description = description
        self.styleHints = styleHints
        self.confidence = confidence
    }

    enum CodingKeys: String, CodingKey {
        case name
        case type
        case description
        case styleHints
        case confidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "component"
        self.description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.styleHints = try container.decodeIfPresent([String: String].self, forKey: .styleHints) ?? [:]
        self.confidence = try container.decodeGeneratedConfidence(forKey: .confidence)
    }
}

public struct HierarchyNode: Codable, Sendable, Identifiable {
    public var id: String
    public var elementId: String
    public var children: [HierarchyNode]
    public var depth: Int

    public init(id: String, elementId: String, children: [HierarchyNode] = [], depth: Int = 0) {
        self.id = id
        self.elementId = elementId
        self.children = children
        self.depth = depth
    }
}

public struct ImplementationGuidance: Codable, Sendable {
    public var framework: String?
    public var layoutStrategy: String?
    public var cssFramework: String?
    public var notes: [String]

    public init(
        framework: String? = nil,
        layoutStrategy: String? = nil,
        cssFramework: String? = nil,
        notes: [String] = []
    ) {
        self.framework = framework
        self.layoutStrategy = layoutStrategy
        self.cssFramework = cssFramework
        self.notes = notes
    }
}

public struct ProjectProfile: Codable, Sendable {
    public var projectId: String
    public var projectName: String
    public var styleSummary: String
    public var brandColors: [NamedColorToken]
    public var typographyScale: [TypographyToken]
    public var spacingScalePx: [Int]
    public var radiiPx: [Int]
    public var shadows: [String]
    public var components: [ComponentProfile]
    public var implementationPreferences: [String]
    public var updatedAt: Date

    public init(
        projectId: String,
        projectName: String = "",
        styleSummary: String = "",
        brandColors: [NamedColorToken] = [],
        typographyScale: [TypographyToken] = [],
        spacingScalePx: [Int] = [],
        radiiPx: [Int] = [],
        shadows: [String] = [],
        components: [ComponentProfile] = [],
        implementationPreferences: [String] = [],
        updatedAt: Date = Date()
    ) {
        self.projectId = projectId
        self.projectName = projectName
        self.styleSummary = styleSummary
        self.brandColors = brandColors
        self.typographyScale = typographyScale
        self.spacingScalePx = spacingScalePx
        self.radiiPx = radiiPx
        self.shadows = shadows
        self.components = components
        self.implementationPreferences = implementationPreferences
        self.updatedAt = updatedAt
    }
}
