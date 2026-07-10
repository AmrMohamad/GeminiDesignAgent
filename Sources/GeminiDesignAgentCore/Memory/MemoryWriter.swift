import Foundation

public struct MemoryWriter: Sendable {
    private let store: DesignMemoryStore

    public init(store: DesignMemoryStore) {
        self.store = store
    }

    public func applyWrites(
        _ writes: [MemoryWrite],
        sourceEvidenceIds: [String],
        projectId: String,
        screenName: String? = nil
    ) async throws -> [String] {
        var writtenIds: [String] = []

        for write in MemoryWritePolicy.validate(writes, screenName: screenName) {
            let atom = MemoryAtom(
                id: StableID.memory(),
                projectId: projectId,
                type: write.type,
                scope: write.scope,
                priority: write.priority,
                sceneName: write.sceneName ?? screenName,
                componentName: write.componentName,
                content: write.content,
                tags: write.tags,
                sourceEvidenceIds: sourceEvidenceIds,
                confidence: write.confidence
            )

            let storedId = try await store.upsertAtom(atom)
            writtenIds.append(storedId)
        }

        return writtenIds
    }
}
