import XCTest
@testable import GeminiDesignAgentCore

final class SQLiteMemoryStoreIntegrationTests: XCTestCase {
    func testMigrationCreatesCoreTablesAndFTS() throws {
        let harness = try makeHarness()

        XCTAssertEqual(try harness.db.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'memory_atoms'"), 1)
        XCTAssertEqual(try harness.db.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'runs'"), 1)
        XCTAssertEqual(try harness.db.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'memory_atoms_fts'"), 1)
    }

    func testRunStatusTransitionsToCompletedAndFailed() throws {
        let harness = try makeHarness()
        let startedAt = Date()

        try harness.store.insertRun(
            id: "run_success",
            sessionId: "session_1",
            screenName: "Home",
            imagePath: "/tmp/home.png",
            model: "gemini-2.5-flash",
            request: "Analyze",
            status: "started",
            startedAt: startedAt,
            completedAt: nil,
            error: nil
        )
        try harness.store.updateRunStatus(id: "run_success", status: "completed", completedAt: Date(), error: nil)
        XCTAssertEqual(try runStatus(db: harness.db, id: "run_success"), "completed")

        try harness.store.insertRun(
            id: "run_failed",
            sessionId: "session_1",
            screenName: "Home",
            imagePath: "/tmp/home.png",
            model: "gemini-2.5-flash",
            request: "Analyze",
            status: "started",
            startedAt: startedAt,
            completedAt: nil,
            error: nil
        )
        try harness.store.updateRunStatus(id: "run_failed", status: "failed", completedAt: Date(), error: "network timeout")

        XCTAssertEqual(try runStatus(db: harness.db, id: "run_failed"), "failed")
        XCTAssertEqual(try runError(db: harness.db, id: "run_failed"), "network timeout")
    }

    func testUpsertDeduplicatesNormalizedContentAndArchivesStoredAtom() async throws {
        let harness = try makeHarness()

        let first = MemoryAtom(
            id: "mem_first",
            projectId: harness.projectId,
            type: .designToken,
            scope: .screen,
            priority: 80,
            sceneName: "Home",
            content: "Primary button uses 12px radius",
            tags: ["button"]
        )
        let second = MemoryAtom(
            id: "mem_second",
            projectId: harness.projectId,
            type: .designToken,
            scope: .screen,
            priority: 90,
            sceneName: "Home",
            content: " primary   BUTTON uses 12px radius ",
            tags: ["button", "radius"]
        )

        let firstId = try await harness.store.upsertAtom(first)
        let secondId = try await harness.store.upsertAtom(second)

        XCTAssertEqual(firstId, "mem_first")
        XCTAssertEqual(secondId, "mem_first")
        XCTAssertEqual(try harness.db.scalarInt("SELECT COUNT(*) FROM memory_atoms"), 1)

        let archived = try latestArchiveLine(recordsDir: harness.recordsDir)
        XCTAssertTrue(archived.contains("\"id\":\"mem_first\""))
        XCTAssertFalse(archived.contains("\"id\":\"mem_second\""))
    }

    func testSearchHonorsTypeScreenComponentGlobalAndLimit() async throws {
        let harness = try makeHarness()

        _ = try await harness.store.upsertAtom(MemoryAtom(
            id: "mem_global",
            projectId: harness.projectId,
            type: .projectStyle,
            scope: .global,
            priority: 99,
            content: "Global button color is gold",
            tags: ["button"]
        ))
        _ = try await harness.store.upsertAtom(MemoryAtom(
            id: "mem_home",
            projectId: harness.projectId,
            type: .designToken,
            scope: .screen,
            priority: 70,
            sceneName: "Home",
            content: "Home button radius is 12px",
            tags: ["button"]
        ))
        _ = try await harness.store.upsertAtom(MemoryAtom(
            id: "mem_card",
            projectId: harness.projectId,
            type: .component,
            scope: .component,
            priority: 70,
            sceneName: "Home",
            componentName: "ProductCard",
            content: "ProductCard button sits below image",
            tags: ["button"]
        ))
        _ = try await harness.store.upsertAtom(MemoryAtom(
            id: "mem_other",
            projectId: harness.projectId,
            type: .designToken,
            scope: .screen,
            priority: 70,
            sceneName: "Other",
            content: "Other button spacing is 8px",
            tags: ["button"]
        ))

        let screenOnly = try await harness.store.searchAtoms(MemoryQuery(
            text: "button",
            limit: 10,
            types: [.designToken],
            screenName: "Home",
            includeGlobal: false
        ))
        XCTAssertEqual(screenOnly.map { $0.atom.id }, ["mem_home"])

        let componentOnly = try await harness.store.searchAtoms(MemoryQuery(
            text: "button",
            limit: 10,
            componentName: "ProductCard",
            includeGlobal: true
        ))
        XCTAssertEqual(componentOnly.map { $0.atom.id }, ["mem_card"])

        let limited = try await harness.store.searchAtoms(MemoryQuery(text: "button", limit: 1, includeGlobal: true))
        XCTAssertEqual(limited.count, 1)
    }

    private struct Harness {
        var tempDir: URL
        var recordsDir: URL
        var db: SQLiteDB
        var store: SQLiteMemoryStore
        var projectId: String
    }

    private func makeHarness() throws -> Harness {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gda-sqlite-tests-\(UUID().uuidString)")
        let recordsDir = tempDir.appendingPathComponent("records")
        try FileManager.default.createDirectory(at: recordsDir, withIntermediateDirectories: true)
        let db = try SQLiteDB(path: tempDir.appendingPathComponent("memory.db").path)
        try DatabaseMigrator.migrate(db: db)
        let projectId = "proj_test"
        let store = try SQLiteMemoryStore(db: db, projectId: projectId, recordsDir: recordsDir)
        return Harness(tempDir: tempDir, recordsDir: recordsDir, db: db, store: store, projectId: projectId)
    }

    private func runStatus(db: SQLiteDB, id: String) throws -> String? {
        let stmt = try db.prepare("SELECT status FROM runs WHERE id = ?")
        defer { stmt.finalize() }
        try stmt.bind(id, at: 1)
        guard try stmt.step() else { return nil }
        return stmt.columnText(0)
    }

    private func runError(db: SQLiteDB, id: String) throws -> String? {
        let stmt = try db.prepare("SELECT error FROM runs WHERE id = ?")
        defer { stmt.finalize() }
        try stmt.bind(id, at: 1)
        guard try stmt.step() else { return nil }
        return stmt.columnText(0)
    }

    private func latestArchiveLine(recordsDir: URL) throws -> String {
        let files = try FileManager.default.contentsOfDirectory(at: recordsDir, includingPropertiesForKeys: nil)
        let file = try XCTUnwrap(files.sorted { $0.lastPathComponent < $1.lastPathComponent }.last)
        let lines = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        return try XCTUnwrap(lines.last)
    }
}
