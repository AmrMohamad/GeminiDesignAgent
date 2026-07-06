import Foundation

public struct MemoryInjection: Sendable {
    public var projectProfile: ProjectProfile?
    public var sceneBlock: SceneBlock?
    public var atoms: [MemorySearchResult]
    public var canvas: String

    public init(
        projectProfile: ProjectProfile? = nil,
        sceneBlock: SceneBlock? = nil,
        atoms: [MemorySearchResult] = [],
        canvas: String = ""
    ) {
        self.projectProfile = projectProfile
        self.sceneBlock = sceneBlock
        self.atoms = atoms
        self.canvas = canvas
    }
}

public struct MemoryRetriever: Sendable {
    private let store: DesignMemoryStore

    public init(store: DesignMemoryStore) {
        self.store = store
    }

    public func retrieve(screenName: String, query: String, limit: Int = 8) async throws -> MemoryInjection {
        async let profile = store.getProjectProfile()
        async let sceneBlock = store.getSceneBlock(name: screenName)
        async let atoms = store.searchAtoms(MemoryQuery(
            text: query,
            limit: limit,
            screenName: screenName,
            includeGlobal: true
        ))

        let (pf, sb, at) = (try await profile, try await sceneBlock, try await atoms)
        let canvas = MemoryCanvasBuilder.build(profile: pf, scene: sb, topAtoms: at.prefix(8).map { $0.atom })

        return MemoryInjection(
            projectProfile: pf,
            sceneBlock: sb,
            atoms: at,
            canvas: canvas
        )
    }
}
