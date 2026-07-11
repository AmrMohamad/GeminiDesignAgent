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

    func testV2ToV3BackfillsEvidenceRelationsFromJSON() throws {
        let db = try makeMigratingDatabase()
        try db.exec("DROP TABLE memory_atom_evidence")
        try db.exec("DROP TABLE migration_backfills")
        try db.exec("DELETE FROM schema_version WHERE version = 3")
        try insertLegacyAtom(db: db, id: "atom_v2", evidenceJSON: "[\"evidence_b\",\"evidence_a\"]")

        try DatabaseMigrator.migrate(db: db)
        try DatabaseMigrator.migrate(db: db)

        XCTAssertEqual(
            try db.scalar("SELECT group_concat(evidence_id, ',') FROM (SELECT evidence_id FROM memory_atom_evidence WHERE atom_id = 'atom_v2' ORDER BY evidence_id)"),
            "evidence_a,evidence_b"
        )
        XCTAssertEqual(try db.scalar("SELECT source_evidence_ids_json FROM memory_atoms WHERE id = 'atom_v2'"), "[\"evidence_a\",\"evidence_b\"]")
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM migration_backfills WHERE name = 'memory_atom_evidence_v3'"), 1)
    }

    func testOldV3RelationWinsOverStaleJSON() throws {
        let db = try makeMigratingDatabase()
        try insertLegacyAtom(db: db, id: "atom_v3", evidenceJSON: "[\"stale_evidence\"]")
        try db.exec("INSERT INTO memory_atom_evidence(atom_id, evidence_id, created_at) VALUES ('atom_v3', 'canonical_evidence', datetime('now'))")
        try db.exec("DELETE FROM migration_backfills WHERE name = 'memory_atom_evidence_v3'")

        try DatabaseMigrator.migrate(db: db)
        try DatabaseMigrator.migrate(db: db)

        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM memory_atom_evidence WHERE atom_id = 'atom_v3' AND evidence_id = 'stale_evidence'"), 0)
        XCTAssertEqual(try db.scalar("SELECT source_evidence_ids_json FROM memory_atoms WHERE id = 'atom_v3'"), "[\"canonical_evidence\"]")
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM migration_backfills WHERE name = 'memory_atom_evidence_v3'"), 1)
    }

    func testOldV3EmptyRelationDoesNotRestoreDeletedJSONEvidence() throws {
        let db = try makeMigratingDatabase()
        try insertLegacyAtom(db: db, id: "atom_v3_empty", evidenceJSON: "[\"deleted_evidence\"]")
        try db.exec("DELETE FROM migration_backfills WHERE name = 'memory_atom_evidence_v3'")

        try DatabaseMigrator.migrate(db: db)
        try DatabaseMigrator.migrate(db: db)

        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM memory_atom_evidence WHERE atom_id = 'atom_v3_empty'"), 0)
        XCTAssertEqual(try db.scalar("SELECT source_evidence_ids_json FROM memory_atoms WHERE id = 'atom_v3_empty'"), "[]")
    }

    func testOldV3PartialRelationIsPreservedAsCanonical() throws {
        let db = try makeMigratingDatabase()
        try insertLegacyAtom(db: db, id: "atom_v3_partial", evidenceJSON: "[\"canonical_a\",\"stale_b\"]")
        try db.exec("INSERT INTO memory_atom_evidence(atom_id, evidence_id, created_at) VALUES ('atom_v3_partial', 'canonical_a', datetime('now'))")
        try db.exec("DELETE FROM migration_backfills WHERE name = 'memory_atom_evidence_v3'")

        try DatabaseMigrator.migrate(db: db)
        try DatabaseMigrator.migrate(db: db)

        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM memory_atom_evidence WHERE atom_id = 'atom_v3_partial'"), 1)
        XCTAssertEqual(try db.scalar("SELECT source_evidence_ids_json FROM memory_atoms WHERE id = 'atom_v3_partial'"), "[\"canonical_a\"]")
    }

    func testMigrationMarkerMakesRepeatedOpenIdempotent() throws {
        let db = try makeMigratingDatabase()
        let completedAt = try db.scalar("SELECT completed_at FROM migration_backfills WHERE name = 'memory_atom_evidence_v3'")
        try DatabaseMigrator.migrate(db: db)
        try DatabaseMigrator.migrate(db: db)

        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM migration_backfills WHERE name = 'memory_atom_evidence_v3'"), 1)
        XCTAssertEqual(try db.scalar("SELECT completed_at FROM migration_backfills WHERE name = 'memory_atom_evidence_v3'"), completedAt)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM schema_version WHERE version = 3"), 1)
    }

    func testMigrationFailureRollsBackAllV3Changes() throws {
        let db = try makeMigratingDatabase()
        try db.exec("DELETE FROM memory_atom_evidence")
        try db.exec("DELETE FROM migration_backfills")
        try db.exec("DELETE FROM schema_version WHERE version = 3")
        try insertLegacyAtom(db: db, id: "atom_rollback", evidenceJSON: "[\"evidence_a\"]")
        try db.exec("""
            CREATE TRIGGER reject_v3_marker
            BEFORE INSERT ON migration_backfills
            BEGIN
                SELECT RAISE(ABORT, 'injected migration failure');
            END
        """)

        XCTAssertThrowsError(try DatabaseMigrator.migrate(db: db))

        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM memory_atom_evidence WHERE atom_id = 'atom_rollback'"), 0)
        XCTAssertEqual(try db.scalar("SELECT source_evidence_ids_json FROM memory_atoms WHERE id = 'atom_rollback'"), "[\"evidence_a\"]")
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM schema_version WHERE version = 3"), 0)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM migration_backfills"), 0)
    }

    func testEvidenceDeletionSurvivesStoreReopen() async throws {
        let harness = try makeHarness()
        let atom = MemoryAtom(
            id: "atom_expired",
            projectId: harness.projectId,
            type: .designToken,
            scope: .screen,
            priority: 50,
            sceneName: "Home",
            content: "Button radius is 12px",
            sourceEvidenceIds: ["evidence_b", "evidence_a"]
        )
        _ = try await harness.store.upsertAtom(atom)

        XCTAssertEqual(try harness.db.scalar("SELECT source_evidence_ids_json FROM memory_atoms WHERE id = 'atom_expired'"), "[\"evidence_a\",\"evidence_b\"]")
        XCTAssertEqual(try harness.store.expireAtoms(sourceEvidenceIds: ["evidence_a", "evidence_b"]), 1)

        let reopened = try SQLiteMemoryStore(db: harness.db, projectId: harness.projectId, recordsDir: harness.recordsDir)
        let reopenedAtom = try await reopened.getAtom(id: "atom_expired")
        let stored = try XCTUnwrap(reopenedAtom)
        XCTAssertTrue(stored.sourceEvidenceIds.isEmpty)
        XCTAssertNotNil(stored.validTo)
    }

    func testGlobalMemoryDemotesWhenOneSupportingScreenRemains() throws {
        let harness = try makeHarness()
        try insertLegacyAtom(db: harness.db, id: "global_atom", evidenceJSON: "[\"evidence_home\",\"evidence_details\"]", projectId: harness.projectId)
        try harness.db.exec("UPDATE memory_atoms SET scope = 'global', scene_name = NULL WHERE id = 'global_atom'")
        try harness.db.exec("INSERT INTO memory_atom_evidence(atom_id, evidence_id, created_at) VALUES ('global_atom', 'evidence_home', datetime('now')), ('global_atom', 'evidence_details', datetime('now'))")
        try insertEvidenceRecord(db: harness.db, id: "evidence_home", screenName: "Home")
        try insertEvidenceRecord(db: harness.db, id: "evidence_details", screenName: "Details")

        XCTAssertEqual(try harness.store.expireAtoms(sourceEvidenceIds: ["evidence_details"]), 0)

        XCTAssertEqual(try harness.db.scalar("SELECT scope FROM memory_atoms WHERE id = 'global_atom'"), "screen")
        XCTAssertEqual(try harness.db.scalar("SELECT scene_name FROM memory_atoms WHERE id = 'global_atom'"), "Home")
    }

    func testGlobalMemoryExpiresWhenNoSupportingScreenRemains() throws {
        let harness = try makeHarness()
        try insertLegacyAtom(db: harness.db, id: "global_atom_empty", evidenceJSON: "[\"evidence_home\"]", projectId: harness.projectId)
        try harness.db.exec("UPDATE memory_atoms SET scope = 'global', scene_name = NULL WHERE id = 'global_atom_empty'")
        try harness.db.exec("INSERT INTO memory_atom_evidence(atom_id, evidence_id, created_at) VALUES ('global_atom_empty', 'evidence_home', datetime('now'))")
        try insertEvidenceRecord(db: harness.db, id: "evidence_home", screenName: "Home")

        XCTAssertEqual(try harness.store.expireAtoms(sourceEvidenceIds: ["evidence_home"]), 1)

        XCTAssertNotNil(try harness.db.scalar("SELECT valid_to FROM memory_atoms WHERE id = 'global_atom_empty'"))
        XCTAssertEqual(try harness.db.scalar("SELECT source_evidence_ids_json FROM memory_atoms WHERE id = 'global_atom_empty'"), "[]")
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

    func testSearchFallsBackDeterministicallyForStopwordOnlyQuery() async throws {
        let harness = try makeHarness()
        _ = try await harness.store.upsertAtom(MemoryAtom(id: "atom_b", projectId: harness.projectId, type: .designToken, scope: .screen, priority: 80, sceneName: "Home", content: "Secondary button", tags: []))
        _ = try await harness.store.upsertAtom(MemoryAtom(id: "atom_a", projectId: harness.projectId, type: .designToken, scope: .screen, priority: 80, sceneName: "Home", content: "Primary button", tags: []))

        let result = try await harness.store.searchAtoms(MemoryQuery(text: "the and of", limit: 10, includeGlobal: false))

        XCTAssertEqual(result.map { $0.atom.id }, ["atom_a", "atom_b"])
    }

    func testSearchNormalizesEmptyPunctuationDuplicateLongAndUnicodeQueries() async throws {
        let harness = try makeHarness()
        _ = try await harness.store.upsertAtom(MemoryAtom(id: "rtl", projectId: harness.projectId, type: .designToken, scope: .screen, priority: 90, sceneName: "Home", content: "زر أساسي primary button", tags: ["button"]))
        _ = try await harness.store.upsertAtom(MemoryAtom(id: "fallback", projectId: harness.projectId, type: .designToken, scope: .screen, priority: 80, sceneName: "Home", content: "Card radius", tags: []))

        for query in ["", "!!!...", "the and of", String(repeating: "primary ", count: 200)] {
            let first = try await harness.store.searchAtoms(MemoryQuery(text: query, limit: 10, includeGlobal: false))
            let second = try await harness.store.searchAtoms(MemoryQuery(text: query, limit: 10, includeGlobal: false))
            XCTAssertEqual(first.map { $0.atom.id }, second.map { $0.atom.id })
            XCTAssertFalse(first.isEmpty)
        }
        let rtl = try await harness.store.searchAtoms(MemoryQuery(text: "زر، زر! أساسي", limit: 10, includeGlobal: false))
        XCTAssertEqual(rtl.first?.atom.id, "rtl")
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
        try DatabaseMigrator.migrate(db: db)
        let projectId = "proj_test"
        let store = try SQLiteMemoryStore(db: db, projectId: projectId, recordsDir: recordsDir)
        return Harness(tempDir: tempDir, recordsDir: recordsDir, db: db, store: store, projectId: projectId)
    }

    private func makeMigratingDatabase() throws -> SQLiteDB {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gda-migration-fixtures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let db = try SQLiteDB(path: tempDir.appendingPathComponent("memory.db").path)
        try DatabaseMigrator.migrate(db: db)
        return db
    }

    private func insertLegacyAtom(db: SQLiteDB, id: String, evidenceJSON: String, projectId: String = "project") throws {
        let statement = try db.prepare("""
            INSERT INTO memory_atoms (
                id, project_id, type, scope, priority, content, tags_json,
                source_evidence_ids_json, valid_from, created_at, updated_at, confidence
            ) VALUES (?, ?, 'design_token', 'screen', 50, 'Legacy memory', '[]', ?, datetime('now'), datetime('now'), datetime('now'), 0.9)
        """)
        defer { statement.finalize() }
        try statement.bind(id, at: 1)
        try statement.bind(projectId, at: 2)
        try statement.bind(evidenceJSON, at: 3)
        _ = try statement.step()
    }

    private func insertEvidenceRecord(db: SQLiteDB, id: String, screenName: String) throws {
        let statement = try db.prepare("""
            INSERT INTO evidence_records (id, run_id, project_id, session_id, screen_name, kind, content_path, created_at)
            VALUES (?, 'run', 'project', 'session', ?, 'analysis', '/tmp/evidence.json', datetime('now'))
        """)
        defer { statement.finalize() }
        try statement.bind(id, at: 1)
        try statement.bind(screenName, at: 2)
        _ = try statement.step()
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
