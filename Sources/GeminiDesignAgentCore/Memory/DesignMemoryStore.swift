import Foundation

public protocol DesignMemoryStore: Sendable {
    @discardableResult
    func upsertAtom(_ atom: MemoryAtom) async throws -> String
    func searchAtoms(_ query: MemoryQuery) async throws -> [MemorySearchResult]
    func getSceneBlock(name: String) async throws -> SceneBlock?
    func upsertSceneBlock(_ scene: SceneBlock) async throws
    func getProjectProfile() async throws -> ProjectProfile?
    func upsertProjectProfile(_ profile: ProjectProfile) async throws
    func getAtom(id: String) async throws -> MemoryAtom?
    func insertEvidenceRecord(id: String, runId: String, sessionId: String, screenName: String?, kind: String, contentPath: String, summary: String?) throws
    func insertRun(id: String, sessionId: String, screenName: String?, imagePath: String, model: String, request: String, status: String, startedAt: Date, completedAt: Date?, error: String?) throws
    func updateRunStatus(id: String, status: String, completedAt: Date?, error: String?) throws
}
