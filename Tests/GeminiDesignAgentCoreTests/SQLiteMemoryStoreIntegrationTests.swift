import XCTest
@testable import GeminiDesignAgentCore

final class SQLiteMemoryStoreIntegrationTests: XCTestCase {
    func testMigrationCreatesCoreTablesAndFTS() throws {
        let harness = try makeHarness()

        XCTAssertEqual(try harness.db.scalar("SELECT sqlite_version()"), "3.53.3")
        XCTAssertEqual(try harness.db.scalarInt("SELECT json_extract('{\"value\":42}', '$.value')"), 42)
        XCTAssertEqual(try harness.db.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'memory_atoms'"), 1)
        XCTAssertEqual(try harness.db.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'runs'"), 1)
        XCTAssertEqual(try harness.db.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'memory_atoms_fts'"), 1)
        try harness.db.exec("INSERT INTO memory_atoms_fts (id, content, tags) VALUES ('fts_probe', 'gold primary button', 'button')")
        XCTAssertEqual(try harness.db.scalarInt("SELECT COUNT(*) FROM memory_atoms_fts WHERE memory_atoms_fts MATCH 'gold'"), 1)
        XCTAssertEqual(try harness.db.integrityCheck(), "ok")
    }

    func testV1MigrationToV2IsAdditiveIdempotentAndPreservesRun() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gda-v1-migration-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let db = try SQLiteDB(path: tempDir.appendingPathComponent("memory.db").path)
        try db.exec("CREATE TABLE schema_version (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)")
        try db.exec("INSERT INTO schema_version (version, applied_at) VALUES (1, datetime('now'))")
        try db.exec("""
            CREATE TABLE runs (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                session_id TEXT NOT NULL,
                screen_name TEXT,
                image_path TEXT NOT NULL,
                model TEXT NOT NULL,
                request TEXT NOT NULL,
                status TEXT NOT NULL,
                started_at TEXT NOT NULL,
                completed_at TEXT,
                error TEXT
            )
        """)
        try db.exec("""
            INSERT INTO runs (
                id, project_id, session_id, screen_name, image_path, model, request, status, started_at
            ) VALUES (
                'run_v1', 'project_v1', 'session_v1', 'Legacy', '/tmp/legacy.png',
                'gemini-2.5-flash', 'Analyze legacy row', 'completed', '2026-07-01T00:00:00Z'
            )
        """)

        try DatabaseMigrator.migrate(db: db)
        try DatabaseMigrator.migrate(db: db)

        XCTAssertEqual(try db.scalarInt("SELECT MAX(version) FROM schema_version"), GDAContract.databaseSchemaVersion)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM schema_version WHERE version = 2"), 1)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM schema_version WHERE version = 3"), 1)
        XCTAssertEqual(try db.scalar("SELECT request FROM runs WHERE id = 'run_v1'"), "Analyze legacy row")
        XCTAssertNil(try db.scalar("SELECT duration_ms FROM runs WHERE id = 'run_v1'"))
        XCTAssertNil(try db.scalar("SELECT gda_version FROM runs WHERE id = 'run_v1'"))
    }

    func testRunStatusTransitionsToCompletedAndFailed() throws {
        let harness = try makeHarness()
        let startedAt = Date()

        try harness.store.insertRun(
            id: "run_success",
            sessionId: "session_1",
            screenName: "Home",
            imagePath: "/tmp/home.png",
            model: GDAContract.defaultModel,
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
            model: GDAContract.defaultModel,
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

    func testListAndGetRuns() throws {
        let harness = try makeHarness()
        let startedAt = Date()

        try harness.store.insertRun(
            id: "run_listed",
            sessionId: "session_1",
            screenName: "Home",
            imagePath: "/tmp/home.png",
            model: GDAContract.defaultModel,
            request: "Analyze",
            status: "started",
            startedAt: startedAt,
            completedAt: nil,
            error: nil
        )

        let runs = try harness.store.listRuns(limit: 10)
        XCTAssertEqual(runs.map(\.id), ["run_listed"])

        let run = try XCTUnwrap(harness.store.getRun(id: "run_listed"))
        XCTAssertEqual(run.screenName, "Home")
        XCTAssertEqual(run.status, "started")
        XCTAssertEqual(run.gdaVersion, GDAContract.productVersion)
        XCTAssertEqual(run.apiVersion, GDAContract.geminiAPIVersion)
    }

    func testRunTelemetryPersistenceAndStatisticsWindow() throws {
        let harness = try makeHarness()
        let now = Date()

        try harness.store.insertRun(
            id: "run_recent",
            sessionId: "session_1",
            screenName: "Home",
            imagePath: "/tmp/home.png",
            model: GDAContract.defaultModel,
            request: "Analyze",
            status: "started",
            startedAt: now,
            completedAt: nil,
            error: nil
        )
        let usage = GeminiUsageMetadata(
            inputTokenCount: 100,
            outputTokenCount: 300,
            thoughtTokenCount: 50,
            cachedTokenCount: 25,
            totalTokenCount: 475,
            raw: .object(["future": .string("preserved")])
        )
        try harness.store.updateRunTelemetry(
            id: "run_recent",
            telemetry: RunTelemetry(model: GDAContract.defaultModel, usage: usage, durationMs: 1_830)
        )
        try harness.store.updateRunStatus(id: "run_recent", status: "completed", completedAt: now, error: nil)

        try harness.store.insertRun(
            id: "run_old",
            sessionId: "session_1",
            screenName: "Old",
            imagePath: "/tmp/old.png",
            model: GDAContract.defaultModel,
            request: "Analyze",
            status: "failed",
            startedAt: now.addingTimeInterval(-60 * 86_400),
            completedAt: now.addingTimeInterval(-60 * 86_400),
            error: "old failure"
        )

        let recent = try XCTUnwrap(harness.store.getRun(id: "run_recent"))
        XCTAssertEqual(recent.inputTokens, 100)
        XCTAssertEqual(recent.outputTokens, 300)
        XCTAssertEqual(recent.thoughtTokens, 50)
        XCTAssertEqual(recent.cachedTokens, 25)
        XCTAssertEqual(recent.totalTokens, 475)
        XCTAssertEqual(recent.durationMs, 1_830)
        XCTAssertEqual(try XCTUnwrap(recent.estimatedCostUSD), 0.00330, accuracy: 0.0000000001)
        XCTAssertEqual(recent.pricingVersion, RunCostEstimator.pricingVersion)
        XCTAssertTrue(recent.usageJSON?.contains("future") == true)

        let statistics = try harness.store.runStatistics(
            since: now.addingTimeInterval(-30 * 86_400),
            requestedSinceDays: 30,
            generatedAt: now
        )
        XCTAssertEqual(statistics.totalRuns, 1)
        XCTAssertEqual(statistics.completedRuns, 1)
        XCTAssertEqual(statistics.failedRuns, 0)
        XCTAssertEqual(statistics.inputTokens, 100)
        XCTAssertEqual(statistics.p95DurationMs, 1_830)
        XCTAssertEqual(statistics.upperBoundEstimatedCostUSD, 0.00330, accuracy: 0.0000000001)
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
