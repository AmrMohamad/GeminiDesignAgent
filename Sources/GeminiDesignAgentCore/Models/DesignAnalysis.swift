import Foundation

public struct ImageSummary: Codable, Sendable {
    public var widthPx: Int
    public var heightPx: Int
    public var mimeType: String

    public init(widthPx: Int, heightPx: Int, mimeType: String) {
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.mimeType = mimeType
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
}
