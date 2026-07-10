import Foundation

public struct ImageSummary: Codable, Sendable {
    public var widthPx: Int
    public var heightPx: Int
    public var mimeType: String
    public var devicePixelRatio: Double?
    public var viewport: String?
    public var theme: String?
    public var state: String?
    public var localeDirection: String?

    public init(
        widthPx: Int,
        heightPx: Int,
        mimeType: String,
        devicePixelRatio: Double? = nil,
        viewport: String? = nil,
        theme: String? = nil,
        state: String? = nil,
        localeDirection: String? = nil
    ) {
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.mimeType = mimeType
        self.devicePixelRatio = devicePixelRatio
        self.viewport = viewport
        self.theme = theme
        self.state = state
        self.localeDirection = localeDirection
    }
}

public struct RunSummary: Codable, Sendable {
    public var id: String
    public var projectId: String
    public var screenName: String?
    public var model: String
    public var startedAt: Date

    public init(id: String, projectId: String, screenName: String? = nil, model: String, startedAt: Date) {
        self.id = id
        self.projectId = projectId
        self.screenName = screenName
        self.model = model
        self.startedAt = startedAt
    }
}

public struct DesignAnalysis: Codable, Sendable {
    public var schemaVersion: String
    public var run: RunSummary?
    public var image: ImageSummary?
    public var summary: String

    public var tokens: DesignTokens
    public var elements: [DesignElement]
    public var hierarchy: [HierarchyNode]
    public var components: [ComponentCandidate]

    public var implementation: ImplementationGuidance?
    public var accessibility: [String]
    public var warnings: [String]

    public var memoryWrites: [MemoryWrite]

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case run
        case image
        case summary
        case tokens
        case elements
        case hierarchy
        case components
        case implementation
        case accessibility
        case warnings
        case memoryWrites
    }

    public init(
        schemaVersion: String = "1.0",
        run: RunSummary? = nil,
        image: ImageSummary? = nil,
        summary: String = "",
        tokens: DesignTokens = DesignTokens(),
        elements: [DesignElement] = [],
        hierarchy: [HierarchyNode] = [],
        components: [ComponentCandidate] = [],
        implementation: ImplementationGuidance? = nil,
        accessibility: [String] = [],
        warnings: [String] = [],
        memoryWrites: [MemoryWrite] = []
    ) {
        self.schemaVersion = schemaVersion
        self.run = run
        self.image = image
        self.summary = summary
        self.tokens = tokens
        self.elements = elements
        self.hierarchy = hierarchy
        self.components = components
        self.implementation = implementation
        self.accessibility = accessibility
        self.warnings = warnings
        self.memoryWrites = memoryWrites
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        self.run = try container.decodeIfPresent(RunSummary.self, forKey: .run)
        self.image = try container.decodeIfPresent(ImageSummary.self, forKey: .image)
        self.summary = try container.decode(String.self, forKey: .summary)
        self.tokens = try container.decode(DesignTokens.self, forKey: .tokens)
        self.elements = try container.decode([DesignElement].self, forKey: .elements)
        self.hierarchy = try container.decodeIfPresent([HierarchyNode].self, forKey: .hierarchy) ?? []
        self.components = try container.decodeIfPresent([ComponentCandidate].self, forKey: .components) ?? []
        self.implementation = try container.decodeIfPresent(ImplementationGuidance.self, forKey: .implementation)
        self.accessibility = try container.decodeIfPresent([String].self, forKey: .accessibility) ?? []
        self.warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        self.memoryWrites = try container.decode([MemoryWrite].self, forKey: .memoryWrites)
    }
}
