import Foundation

public struct MemoryInjectionBuilder: Sendable {
    private let memory: DesignMemoryStore

    public init(memory: DesignMemoryStore) {
        self.memory = memory
    }

    public func build(
        screenName: String,
        request: String,
        limit: Int = 8
    ) async throws -> MemoryInjection {
        let retriever = MemoryRetriever(store: memory)
        return try await retriever.retrieve(screenName: screenName, query: request, limit: limit)
    }
}
