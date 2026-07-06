import Foundation

public struct SceneBlock: Codable, Sendable, Identifiable {
    public var id: String
    public var projectId: String
    public var name: String
    public var summary: String
    public var keyComponents: [String]
    public var keyTokens: [String]
    public var memoryAtomIds: [String]
    public var evidenceIds: [String]
    public var updatedAt: Date

    public init(
        id: String,
        projectId: String,
        name: String,
        summary: String,
        keyComponents: [String] = [],
        keyTokens: [String] = [],
        memoryAtomIds: [String] = [],
        evidenceIds: [String] = [],
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.projectId = projectId
        self.name = name
        self.summary = summary
        self.keyComponents = keyComponents
        self.keyTokens = keyTokens
        self.memoryAtomIds = memoryAtomIds
        self.evidenceIds = evidenceIds
        self.updatedAt = updatedAt
    }
}
