import Foundation

public protocol DesignMemoryStore: Sendable {
    func upsertAtom(_ atom: MemoryAtom) async throws
    func searchAtoms(_ query: MemoryQuery) async throws -> [MemorySearchResult]
    func getSceneBlock(name: String) async throws -> SceneBlock?
    func upsertSceneBlock(_ scene: SceneBlock) async throws
    func getProjectProfile() async throws -> ProjectProfile?
    func upsertProjectProfile(_ profile: ProjectProfile) async throws
    func getAtom(id: String) async throws -> MemoryAtom?
}
