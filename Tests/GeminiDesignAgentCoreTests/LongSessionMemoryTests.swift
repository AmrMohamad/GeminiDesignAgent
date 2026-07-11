import XCTest
@testable import GeminiDesignAgentCore

final class LongSessionMemoryTests: XCTestCase {
    func testHundredAnalysesRemainDeduplicatedAndPromptBoundedAcrossReopen() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("gda-long-session-\(UUID().uuidString)")
        let records = temp.appendingPathComponent("records")
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        let db = try SQLiteDB(path: temp.appendingPathComponent("memory.db").path)
        let projectID = "long_session"
        let store = try SQLiteMemoryStore(db: db, projectId: projectID, recordsDir: records)

        for index in 0..<100 {
            _ = try await store.upsertAtom(MemoryAtom(
                id: "atom_\(index)", projectId: projectID, type: .designToken,
                scope: .screen, priority: 80, sceneName: "Screen \(index % 5)",
                content: "Primary button uses 12px radius", tags: ["button"]
            ))
        }

        let initialStats = try await store.stats()
        XCTAssertEqual(initialStats.atomCount, 5)
        let atoms = try await store.searchAtoms(MemoryQuery(text: "primary button", limit: 100, includeGlobal: false))
        let prompt = DesignPromptBuilder.build(
            screenName: "Screen 0", request: "Analyze", 
            imageInfo: ImageInfo(width: 100, height: 100, mimeType: "image/png", fileSize: 1, format: .png),
            memory: MemoryInjection(atoms: atoms)
        )
        XCTAssertLessThanOrEqual(prompt.user.count, 7_500)

        let reopened = try SQLiteMemoryStore(db: db, projectId: projectID, recordsDir: records)
        let reopenedStats = try await reopened.stats()
        XCTAssertEqual(reopenedStats.atomCount, 5)
    }
}
