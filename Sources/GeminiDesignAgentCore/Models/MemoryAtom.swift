import Foundation

public enum MemoryAtomType: String, Codable, Sendable {
    case projectStyle
    case designToken
    case component
    case layoutRule
    case spacingRule
    case typographyRule
    case screenFact
    case implementationInstruction
    case userPreference
    case warning
}

public enum MemoryScope: String, Codable, Sendable {
    case global
    case screen
    case component
    case session
}

public struct MemoryAtom: Codable, Sendable, Identifiable {
    public var id: String
    public var projectId: String

    public var type: MemoryAtomType
    public var scope: MemoryScope
    public var priority: Int

    public var sceneName: String?
    public var componentName: String?
    public var content: String
    public var tags: [String]

    public var sourceEvidenceIds: [String]
    public var validFrom: Date
    public var validTo: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public var confidence: Double

    public init(
        id: String,
        projectId: String,
        type: MemoryAtomType,
        scope: MemoryScope,
        priority: Int,
        sceneName: String? = nil,
        componentName: String? = nil,
        content: String,
        tags: [String] = [],
        sourceEvidenceIds: [String] = [],
        validFrom: Date = Date(),
        validTo: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        confidence: Double = 1.0
    ) {
        self.id = id
        self.projectId = projectId
        self.type = type
        self.scope = scope
        self.priority = priority
        self.sceneName = sceneName
        self.componentName = componentName
        self.content = content
        self.tags = tags
        self.sourceEvidenceIds = sourceEvidenceIds
        self.validFrom = validFrom
        self.validTo = validTo
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.confidence = confidence
    }
}

public struct MemoryQuery: Codable, Sendable {
    public var text: String
    public var limit: Int
    public var types: [MemoryAtomType]
    public var screenName: String?
    public var componentName: String?
    public var includeGlobal: Bool

    public init(
        text: String,
        limit: Int = 8,
        types: [MemoryAtomType] = [],
        screenName: String? = nil,
        componentName: String? = nil,
        includeGlobal: Bool = true
    ) {
        self.text = text
        self.limit = limit
        self.types = types
        self.screenName = screenName
        self.componentName = componentName
        self.includeGlobal = includeGlobal
    }
}

public struct MemorySearchResult: Codable, Sendable {
    public var atom: MemoryAtom
    public var score: Double
    public var matchSnippet: String?

    public init(atom: MemoryAtom, score: Double, matchSnippet: String? = nil) {
        self.atom = atom
        self.score = score
        self.matchSnippet = matchSnippet
    }
}

public struct MemoryWrite: Codable, Sendable {
    public var type: MemoryAtomType
    public var scope: MemoryScope
    public var priority: Int
    public var sceneName: String?
    public var componentName: String?
    public var content: String
    public var tags: [String]
    public var confidence: Double

    public init(
        type: MemoryAtomType,
        scope: MemoryScope,
        priority: Int,
        sceneName: String? = nil,
        componentName: String? = nil,
        content: String,
        tags: [String] = [],
        confidence: Double = 1.0
    ) {
        self.type = type
        self.scope = scope
        self.priority = priority
        self.sceneName = sceneName
        self.componentName = componentName
        self.content = content
        self.tags = tags
        self.confidence = confidence
    }
}
