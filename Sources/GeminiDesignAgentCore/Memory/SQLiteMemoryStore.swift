import Foundation

public struct MemoryStoreStats: Codable, Sendable {
    public var atomCount: Int
    public var sceneCount: Int
    public var hasProjectProfile: Bool
}

public struct EvidenceRecord: Codable, Sendable {
    public var id: String
    public var runId: String
    public var projectId: String
    public var sessionId: String
    public var screenName: String?
    public var kind: String
    public var contentPath: String
    public var summary: String?
    public var createdAt: Date
}

public final class SQLiteMemoryStore: DesignMemoryStore {
    private static let globallyPromotableTypes: Set<MemoryAtomType> = [
        .projectStyle, .designToken, .component, .layoutRule, .spacingRule, .typographyRule
    ]
    private let db: SQLiteDB
    private let projectId: String
    private let jsonlStore: JSONLArchiveStore
    private let clock: Clock

    public init(db: SQLiteDB, projectId: String, recordsDir: URL, clock: Clock = .system) throws {
        self.db = db
        self.projectId = projectId
        self.jsonlStore = JSONLArchiveStore(recordsDir: recordsDir)
        self.clock = clock
        try DatabaseMigrator.migrate(db: db)
        try completeV3EvidenceBackfillIfNeeded()
    }

    @discardableResult
    public func upsertAtom(_ atom: MemoryAtom) async throws -> String {
        let now = clock.now()

        let storedAtom: MemoryAtom = try db.withLock {
            try db.transaction {
                var candidate = atom
                if candidate.scope == .screen,
                   Self.globallyPromotableTypes.contains(candidate.type),
                   candidate.confidence >= 0.75,
                   let supporting = try findSupportingScreenAtom(candidate),
                   !Set(supporting.sourceEvidenceIds).isSubset(of: Set(candidate.sourceEvidenceIds)) {
                    candidate.scope = .global
                    candidate.sceneName = nil
                    candidate.sourceEvidenceIds = Array(Set(candidate.sourceEvidenceIds + supporting.sourceEvidenceIds)).sorted()
                }
                let existing = try findExistingAtom(candidate)

                if let existing = existing {
                    var updated = candidate
                    updated.id = existing.id
                    updated.createdAt = existing.createdAt
                    updated.updatedAt = now
                    updated.tags = Array(Set(existing.tags + atom.tags)).sorted()
                    updated.sourceEvidenceIds = Array(Set(existing.sourceEvidenceIds + atom.sourceEvidenceIds)).sorted()
                    updated.priority = max(existing.priority, atom.priority)
                    updated.confidence = min(1, max(0, (existing.confidence + atom.confidence) / 2))
                    try updateAtom(updated)
                    try updateFTS(updated)
                    try linkEvidence(updated.sourceEvidenceIds, atomID: updated.id, at: now)
                    return updated
                } else {
                    var newAtom = candidate
                    if newAtom.id.isEmpty {
                        newAtom.id = StableID.memory()
                    }
                    newAtom.createdAt = now
                    newAtom.updatedAt = now
                    try insertAtom(newAtom)
                    try insertFTS(newAtom)
                    try linkEvidence(newAtom.sourceEvidenceIds, atomID: newAtom.id, at: now)
                    return newAtom
                }
            }
        }

        try await jsonlStore.append(storedAtom, date: now)
        return storedAtom.id
    }

    public func searchAtoms(_ query: MemoryQuery) async throws -> [MemorySearchResult] {
        let now = clock.now()
        var results: [MemorySearchResult] = []

        let ftsResults = try db.withLock { try searchFTS(query) }

        let maxBM25 = ftsResults.map(\.2).max() ?? 0
        for (atom, snippet, rawBM25) in ftsResults {
            let bm25Score = maxBM25 > 0 ? rawBM25 / maxBM25 : 0
            let score = MemoryRanking.rank(
                bm25Score: bm25Score,
                atom: atom,
                query: query,
                now: now
            )
            results.append(MemorySearchResult(atom: atom, score: score, matchSnippet: snippet))
        }

        if query.includeGlobal && query.componentName == nil {
            let highPriorityGlobals = try db.withLock { try fetchHighPriorityGlobals(query: query) }
            for atom in highPriorityGlobals {
                if !results.contains(where: { $0.atom.id == atom.id }) {
                    results.append(MemorySearchResult(atom: atom, score: Double(atom.priority) * 0.1))
                }
            }
        }

        results.sort { $0.score > $1.score }
        return Array(results.prefix(query.limit))
    }

    public func getSceneBlock(name: String) async throws -> SceneBlock? {
        try db.withLock {
            try getSceneBlockSync(name: name)
        }
    }

    private func getSceneBlockSync(name: String) throws -> SceneBlock? {
        let stmt = try db.prepare(
            "SELECT id, project_id, name, summary, key_components_json, key_tokens_json, memory_atom_ids_json, evidence_ids_json, updated_at FROM scene_blocks WHERE project_id = ? AND name = ?"
        )
        defer { stmt.finalize() }

        try stmt.bind(projectId, at: 1)
        try stmt.bind(name, at: 2)

        guard try stmt.step() else { return nil }

        return SceneBlock(
            id: stmt.columnText(0) ?? "",
            projectId: stmt.columnText(1) ?? "",
            name: stmt.columnText(2) ?? "",
            summary: stmt.columnText(3) ?? "",
            keyComponents: decodeJSONArray(stmt.columnText(4)) ?? [],
            keyTokens: decodeJSONArray(stmt.columnText(5)) ?? [],
            memoryAtomIds: decodeJSONArray(stmt.columnText(6)) ?? [],
            evidenceIds: decodeJSONArray(stmt.columnText(7)) ?? [],
            updatedAt: parseDate(stmt.columnText(8)) ?? Date()
        )
    }

    public func upsertSceneBlock(_ scene: SceneBlock) async throws {
        try db.withLock {
            let nowStr = iso8601(clock.now())

            let stmt = try db.prepare("""
                INSERT INTO scene_blocks (id, project_id, name, summary, key_components_json, key_tokens_json, memory_atom_ids_json, evidence_ids_json, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(project_id, name) DO UPDATE SET
                    id = excluded.id,
                    summary = excluded.summary,
                    key_components_json = excluded.key_components_json,
                    key_tokens_json = excluded.key_tokens_json,
                    memory_atom_ids_json = excluded.memory_atom_ids_json,
                    evidence_ids_json = excluded.evidence_ids_json,
                    updated_at = excluded.updated_at
            """)
            defer { stmt.finalize() }

            try stmt.bind(scene.id, at: 1)
            try stmt.bind(scene.projectId, at: 2)
            try stmt.bind(scene.name, at: 3)
            try stmt.bind(scene.summary, at: 4)
            try stmt.bind(encodeJSONArray(scene.keyComponents), at: 5)
            try stmt.bind(encodeJSONArray(scene.keyTokens), at: 6)
            try stmt.bind(encodeJSONArray(scene.memoryAtomIds), at: 7)
            try stmt.bind(encodeJSONArray(scene.evidenceIds), at: 8)
            try stmt.bind(nowStr, at: 9)

            _ = try stmt.step()
        }
    }

    public func getProjectProfile() async throws -> ProjectProfile? {
        try db.withLock {
            try getProjectProfileSync()
        }
    }

    private func getProjectProfileSync() throws -> ProjectProfile? {
        let stmt = try db.prepare(
            "SELECT profile_json FROM project_profiles WHERE project_id = ?"
        )
        defer { stmt.finalize() }

        try stmt.bind(projectId, at: 1)

        guard try stmt.step(), let json = stmt.columnText(0) else { return nil }

        return try? JSON.decoder.decode(ProjectProfile.self, from: Data(json.utf8))
    }

    public func upsertProjectProfile(_ profile: ProjectProfile) async throws {
        try db.withLock {
            let nowStr = iso8601(clock.now())
            let json = String(data: try JSON.compactEncoder.encode(profile), encoding: .utf8) ?? "{}"

            let stmt = try db.prepare("""
                INSERT INTO project_profiles (project_id, project_name, profile_json, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(project_id) DO UPDATE SET
                    project_name = excluded.project_name,
                    profile_json = excluded.profile_json,
                    updated_at = excluded.updated_at
            """)
            defer { stmt.finalize() }

            try stmt.bind(profile.projectId, at: 1)
            try stmt.bind(profile.projectName, at: 2)
            try stmt.bind(json, at: 3)
            try stmt.bind(nowStr, at: 4)

            _ = try stmt.step()
        }
    }

    public func getAtom(id: String) async throws -> MemoryAtom? {
        try db.withLock {
            try getAtomSync(id: id)
        }
    }

    private func getAtomSync(id: String) throws -> MemoryAtom? {
        let stmt = try db.prepare(
            "SELECT id, project_id, type, scope, priority, scene_name, component_name, content, tags_json, source_evidence_ids_json, valid_from, valid_to, created_at, updated_at, confidence FROM memory_atoms WHERE id = ?"
        )
        defer { stmt.finalize() }

        try stmt.bind(id, at: 1)

        guard try stmt.step() else { return nil }

        return rowToAtom(stmt)
    }

    public func insertEvidenceRecord(
        id: String,
        runId: String,
        sessionId: String,
        screenName: String?,
        kind: String,
        contentPath: String,
        summary: String? = nil
    ) throws {
        try db.withLock {
            let nowStr = iso8601(clock.now())
            let stmt = try db.prepare("""
                INSERT INTO evidence_records (id, run_id, project_id, session_id, screen_name, kind, content_path, summary, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
            defer { stmt.finalize() }

            try stmt.bind(id, at: 1)
            try stmt.bind(runId, at: 2)
            try stmt.bind(projectId, at: 3)
            try stmt.bind(sessionId, at: 4)
            try bindOptional(stmt, screenName, at: 5)
            try stmt.bind(kind, at: 6)
            try stmt.bind(contentPath, at: 7)
            try bindOptional(stmt, summary, at: 8)
            try stmt.bind(nowStr, at: 9)

            _ = try stmt.step()
        }
    }

    public func insertRun(
        id: String,
        sessionId: String,
        screenName: String?,
        imagePath: String,
        model: String,
        request: String,
        status: String,
        startedAt: Date,
        completedAt: Date? = nil,
        error: String? = nil
    ) throws {
        try db.withLock {
            let stmt = try db.prepare("""
                INSERT INTO runs (
                    id, project_id, session_id, screen_name, image_path, model, request, status,
                    started_at, completed_at, error, gda_version, api_version,
                    prompt_schema_version, analysis_schema_version
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
            defer { stmt.finalize() }

            try stmt.bind(id, at: 1)
            try stmt.bind(projectId, at: 2)
            try stmt.bind(sessionId, at: 3)
            try bindOptional(stmt, screenName, at: 4)
            try stmt.bind(imagePath, at: 5)
            try stmt.bind(model, at: 6)
            try stmt.bind(request, at: 7)
            try stmt.bind(status, at: 8)
            try stmt.bind(iso8601(startedAt), at: 9)
            try bindOptional(stmt, completedAt.map { iso8601($0) }, at: 10)
            try bindOptional(stmt, error, at: 11)
            try stmt.bind(GDAContract.productVersion, at: 12)
            try stmt.bind(GDAContract.geminiAPIVersion, at: 13)
            try stmt.bind(GDAContract.promptSchemaVersion, at: 14)
            try stmt.bind(GDAContract.analysisSchemaVersion, at: 15)

            _ = try stmt.step()
        }
    }

    public func updateRunStatus(id: String, status: String, completedAt: Date?, error: String?) throws {
        try db.withLock {
            let stmt = try db.prepare("""
                UPDATE runs SET status = ?, completed_at = ?, error = ? WHERE id = ? AND project_id = ?
            """)
            defer { stmt.finalize() }

            try stmt.bind(status, at: 1)
            try bindOptional(stmt, completedAt.map { iso8601($0) }, at: 2)
            try bindOptional(stmt, error, at: 3)
            try stmt.bind(id, at: 4)
            try stmt.bind(projectId, at: 5)

            _ = try stmt.step()
        }
    }

    public func updateRunTelemetry(id: String, telemetry: RunTelemetry) throws {
        try db.withLock {
            let stmt = try db.prepare("""
                UPDATE runs SET
                    gda_version = ?, api_version = ?, prompt_schema_version = ?, analysis_schema_version = ?,
                    input_tokens = ?, output_tokens = ?, thought_tokens = ?, cached_tokens = ?, total_tokens = ?,
                    duration_ms = ?, usage_json = ?, estimated_cost_usd = ?, pricing_version = ?
                WHERE id = ? AND project_id = ?
            """)
            defer { stmt.finalize() }

            try stmt.bind(telemetry.metrics.gdaVersion, at: 1)
            try stmt.bind(telemetry.metrics.apiVersion, at: 2)
            try stmt.bind(telemetry.metrics.promptSchemaVersion, at: 3)
            try stmt.bind(telemetry.metrics.analysisSchemaVersion, at: 4)
            try bindOptional(stmt, telemetry.usage?.inputTokens, at: 5)
            try bindOptional(stmt, telemetry.usage?.outputTokens, at: 6)
            try bindOptional(stmt, telemetry.usage?.thoughtTokens, at: 7)
            try bindOptional(stmt, telemetry.usage?.cachedTokens, at: 8)
            try bindOptional(stmt, telemetry.usage?.totalTokens, at: 9)
            try stmt.bind(telemetry.metrics.durationMs, at: 10)
            try bindOptional(stmt, telemetry.usageJSON, at: 11)
            try bindOptional(stmt, telemetry.metrics.upperBoundEstimatedCostUSD, at: 12)
            try bindOptional(stmt, telemetry.metrics.pricingVersion, at: 13)
            try stmt.bind(id, at: 14)
            try stmt.bind(projectId, at: 15)

            _ = try stmt.step()
        }
    }

    public func stats() async throws -> MemoryStoreStats {
        try db.withLock {
            let atomCount = try count("SELECT COUNT(*) FROM memory_atoms WHERE project_id = ?", value: projectId)
            let sceneCount = try count("SELECT COUNT(*) FROM scene_blocks WHERE project_id = ?", value: projectId)
            let profileCount = try count("SELECT COUNT(*) FROM project_profiles WHERE project_id = ?", value: projectId)
            return MemoryStoreStats(atomCount: atomCount, sceneCount: sceneCount, hasProjectProfile: profileCount > 0)
        }
    }

    public func listRuns(limit: Int = 50) throws -> [RunRecord] {
        try db.withLock {
            let stmt = try db.prepare("""
                SELECT id, project_id, session_id, screen_name, image_path, model, request, status,
                       started_at, completed_at, error, gda_version, api_version, prompt_schema_version,
                       analysis_schema_version, input_tokens, output_tokens, thought_tokens, cached_tokens,
                       total_tokens, duration_ms, usage_json, estimated_cost_usd, pricing_version
                FROM runs
                WHERE project_id = ?
                ORDER BY started_at DESC
                LIMIT ?
            """)
            defer { stmt.finalize() }

            try stmt.bind(projectId, at: 1)
            try stmt.bind(max(1, limit), at: 2)

            var runs: [RunRecord] = []
            while try stmt.step() {
                runs.append(rowToRun(stmt))
            }
            return runs
        }
    }

    public func runStatistics(since: Date, requestedSinceDays: Int, generatedAt: Date = Date()) throws -> RunStatistics {
        let runs: [RunRecord] = try db.withLock {
            let stmt = try db.prepare("""
                SELECT id, project_id, session_id, screen_name, image_path, model, request, status,
                       started_at, completed_at, error, gda_version, api_version, prompt_schema_version,
                       analysis_schema_version, input_tokens, output_tokens, thought_tokens, cached_tokens,
                       total_tokens, duration_ms, usage_json, estimated_cost_usd, pricing_version
                FROM runs
                WHERE project_id = ? AND started_at >= ?
                ORDER BY started_at DESC
            """)
            defer { stmt.finalize() }

            try stmt.bind(projectId, at: 1)
            try stmt.bind(iso8601(since), at: 2)

            var runs: [RunRecord] = []
            while try stmt.step() {
                runs.append(rowToRun(stmt))
            }
            return runs
        }

        return RunStatistics.calculate(
            runs: runs,
            requestedSinceDays: requestedSinceDays,
            since: since,
            generatedAt: generatedAt
        )
    }

    public func getRun(id: String) throws -> RunRecord? {
        try db.withLock {
            let stmt = try db.prepare("""
                SELECT id, project_id, session_id, screen_name, image_path, model, request, status,
                       started_at, completed_at, error, gda_version, api_version, prompt_schema_version,
                       analysis_schema_version, input_tokens, output_tokens, thought_tokens, cached_tokens,
                       total_tokens, duration_ms, usage_json, estimated_cost_usd, pricing_version
                FROM runs
                WHERE project_id = ? AND id = ?
            """)
            defer { stmt.finalize() }

            try stmt.bind(projectId, at: 1)
            try stmt.bind(id, at: 2)

            guard try stmt.step() else { return nil }
            return rowToRun(stmt)
        }
    }

    public func evidenceRecords(runId: String) throws -> [EvidenceRecord] {
        try db.withLock {
            let stmt = try db.prepare("""
                SELECT id, run_id, project_id, session_id, screen_name, kind, content_path, summary, created_at
                FROM evidence_records
                WHERE project_id = ? AND run_id = ?
                ORDER BY created_at ASC
            """)
            defer { stmt.finalize() }

            try stmt.bind(projectId, at: 1)
            try stmt.bind(runId, at: 2)

            var records: [EvidenceRecord] = []
            while try stmt.step() {
                records.append(EvidenceRecord(
                    id: stmt.columnText(0) ?? "",
                    runId: stmt.columnText(1) ?? "",
                    projectId: stmt.columnText(2) ?? "",
                    sessionId: stmt.columnText(3) ?? "",
                    screenName: stmt.columnText(4),
                    kind: stmt.columnText(5) ?? "",
                    contentPath: stmt.columnText(6) ?? "",
                    summary: stmt.columnText(7),
                    createdAt: parseDate(stmt.columnText(8)) ?? Date()
                ))
            }
            return records
        }
    }

    public func expireAtoms(sourceEvidenceIds: [String], at date: Date = Date()) throws -> Int {
        guard !sourceEvidenceIds.isEmpty else { return 0 }

        return try db.withLock {
            var expired = 0
            let now = iso8601(date)

            for evidenceId in sourceEvidenceIds {
                let delete = try db.prepare("DELETE FROM memory_atom_evidence WHERE evidence_id = ?")
                try delete.bind(evidenceId, at: 1); _ = try delete.step(); delete.finalize()
            }
            try refreshEvidenceProjections()
            let stmt = try db.prepare("""
                UPDATE memory_atoms SET valid_to = ?, updated_at = ?
                WHERE project_id = ? AND valid_to IS NULL
                  AND NOT EXISTS (SELECT 1 FROM memory_atom_evidence e WHERE e.atom_id = memory_atoms.id)
            """)
            defer { stmt.finalize() }
            try stmt.bind(now, at: 1); try stmt.bind(now, at: 2); try stmt.bind(projectId, at: 3)
            _ = try stmt.step(); expired = db.changeCount()

            return expired
        }
    }

    public func activeAtoms(limit: Int = 10_000) throws -> [MemoryAtom] {
        try db.withLock {
            let nowIso = iso8601(clock.now())
            let stmt = try db.prepare("""
                SELECT id, project_id, type, scope, priority, scene_name, component_name,
                       content, tags_json, source_evidence_ids_json, valid_from, valid_to,
                       created_at, updated_at, confidence
                FROM memory_atoms
                WHERE project_id = ?
                  AND (valid_to IS NULL OR valid_to > ?)
                ORDER BY priority DESC, updated_at DESC
                LIMIT ?
            """)
            defer { stmt.finalize() }

            try stmt.bind(projectId, at: 1)
            try stmt.bind(nowIso, at: 2)
            try stmt.bind(max(1, limit), at: 3)

            var atoms: [MemoryAtom] = []
            while try stmt.step() {
                atoms.append(rowToAtom(stmt))
            }
            return atoms
        }
    }

    public func lowConfidencePruneCandidates(olderThan date: Date, confidenceBelow threshold: Double, limit: Int = 10_000) throws -> [MemoryAtom] {
        try db.withLock {
            let cutoff = iso8601(date)
            let stmt = try db.prepare("""
                SELECT id, project_id, type, scope, priority, scene_name, component_name,
                       content, tags_json, source_evidence_ids_json, valid_from, valid_to,
                       created_at, updated_at, confidence
                FROM memory_atoms
                WHERE project_id = ?
                  AND valid_to IS NULL
                  AND confidence < ?
                  AND updated_at < ?
                ORDER BY confidence ASC, updated_at ASC
                LIMIT ?
            """)
            defer { stmt.finalize() }

            try stmt.bind(projectId, at: 1)
            try stmt.bind(threshold, at: 2)
            try stmt.bind(cutoff, at: 3)
            try stmt.bind(max(1, limit), at: 4)

            var atoms: [MemoryAtom] = []
            while try stmt.step() {
                atoms.append(rowToAtom(stmt))
            }
            return atoms
        }
    }

    public func expireAtoms(ids: [String], at date: Date = Date()) throws -> Int {
        guard !ids.isEmpty else { return 0 }

        return try db.withLock {
            var expired = 0
            let now = iso8601(date)

            for id in ids {
                let stmt = try db.prepare("""
                    UPDATE memory_atoms
                    SET valid_to = ?, updated_at = ?
                    WHERE project_id = ? AND id = ? AND valid_to IS NULL
                """)
                defer { stmt.finalize() }

                try stmt.bind(now, at: 1)
                try stmt.bind(now, at: 2)
                try stmt.bind(projectId, at: 3)
                try stmt.bind(id, at: 4)
                _ = try stmt.step()
                expired += db.changeCount()
            }

            return expired
        }
    }

    private func findExistingAtom(_ atom: MemoryAtom) throws -> MemoryAtom? {
        let normalized = normalizeContent(atom.content)

        let stmt = try db.prepare("""
            SELECT id, content FROM memory_atoms
            WHERE project_id = ? AND type = ? AND scope = ?
              AND (scene_name = ? OR (scene_name IS NULL AND ? IS NULL))
              AND (component_name = ? OR (component_name IS NULL AND ? IS NULL))
        """)
        defer { stmt.finalize() }

        try stmt.bind(projectId, at: 1)
        try stmt.bind(atom.type.rawValue, at: 2)
        try stmt.bind(atom.scope.rawValue, at: 3)
        try bindOptional(stmt, atom.sceneName, at: 4)
        try bindOptional(stmt, atom.sceneName, at: 5)
        try bindOptional(stmt, atom.componentName, at: 6)
        try bindOptional(stmt, atom.componentName, at: 7)

        while try stmt.step() {
            guard let id = stmt.columnText(0), let content = stmt.columnText(1) else { continue }
            if normalizeContent(content) == normalized {
                return try getAtomSync(id: id)
            }
        }

        return nil
    }

    private func findSupportingScreenAtom(_ atom: MemoryAtom) throws -> MemoryAtom? {
        guard let sceneName = atom.sceneName else { return nil }
        let normalized = normalizeContent(atom.content)
        let stmt = try db.prepare("""
            SELECT id, content FROM memory_atoms
            WHERE project_id = ? AND type = ? AND scope = 'screen'
              AND scene_name IS NOT NULL AND scene_name != ?
              AND (component_name = ? OR (component_name IS NULL AND ? IS NULL))
              AND valid_to IS NULL
        """)
        defer { stmt.finalize() }
        try stmt.bind(projectId, at: 1)
        try stmt.bind(atom.type.rawValue, at: 2)
        try stmt.bind(sceneName, at: 3)
        try bindOptional(stmt, atom.componentName, at: 4)
        try bindOptional(stmt, atom.componentName, at: 5)
        while try stmt.step() {
            guard let id = stmt.columnText(0), let content = stmt.columnText(1) else { continue }
            if normalizeContent(content) == normalized { return try getAtomSync(id: id) }
        }
        return nil
    }

    private func completeV3EvidenceBackfillIfNeeded() throws {
        try db.withLock {
            if try db.scalar("SELECT name FROM migration_backfills WHERE name = 'memory_atom_evidence_v3'") != nil {
                return
            }
            try db.transaction {
                try backfillEvidenceLinks()
                try db.exec("INSERT INTO migration_backfills(name, completed_at) VALUES ('memory_atom_evidence_v3', datetime('now'))")
            }
        }
    }

    private func backfillEvidenceLinks() throws {
        let stmt = try db.prepare("SELECT id, source_evidence_ids_json, created_at FROM memory_atoms")
        defer { stmt.finalize() }
        while try stmt.step() {
            guard let atomID = stmt.columnText(0) else { continue }
            let ids = decodeJSONArray(stmt.columnText(1)) ?? []
            try linkEvidence(ids, atomID: atomID, at: parseDate(stmt.columnText(2)) ?? clock.now())
        }
    }

    private func refreshEvidenceProjections() throws {
        let atoms = try db.prepare("SELECT id FROM memory_atoms WHERE project_id = ?")
        defer { atoms.finalize() }
        try atoms.bind(projectId, at: 1)
        while try atoms.step() {
            guard let atomID = atoms.columnText(0) else { continue }
            let evidence = try db.prepare("SELECT evidence_id FROM memory_atom_evidence WHERE atom_id = ? ORDER BY evidence_id")
            try evidence.bind(atomID, at: 1)
            var ids: [String] = []
            while try evidence.step() { if let id = evidence.columnText(0) { ids.append(id) } }
            evidence.finalize()
            let update = try db.prepare("UPDATE memory_atoms SET source_evidence_ids_json = ? WHERE id = ?")
            try update.bind(encodeJSONArray(ids), at: 1)
            try update.bind(atomID, at: 2)
            _ = try update.step()
            update.finalize()
        }
    }

    private func linkEvidence(_ ids: [String], atomID: String, at date: Date) throws {
        guard !ids.isEmpty else { return }
        let stmt = try db.prepare("INSERT OR IGNORE INTO memory_atom_evidence(atom_id, evidence_id, created_at) VALUES (?, ?, ?)")
        defer { stmt.finalize() }
        for id in Set(ids) {
            try stmt.bind(atomID, at: 1)
            try stmt.bind(id, at: 2)
            try stmt.bind(iso8601(date), at: 3)
            _ = try stmt.step()
            try stmt.reset()
        }
    }

    private func insertAtom(_ atom: MemoryAtom) throws {
        let stmt = try db.prepare("""
            INSERT INTO memory_atoms (id, project_id, type, scope, priority, scene_name, component_name, content, tags_json, source_evidence_ids_json, valid_from, valid_to, created_at, updated_at, confidence)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """)
        defer { stmt.finalize() }

        try stmt.bind(atom.id, at: 1)
        try stmt.bind(atom.projectId, at: 2)
        try stmt.bind(atom.type.rawValue, at: 3)
        try stmt.bind(atom.scope.rawValue, at: 4)
        try stmt.bind(atom.priority, at: 5)
        try bindOptional(stmt, atom.sceneName, at: 6)
        try bindOptional(stmt, atom.componentName, at: 7)
        try stmt.bind(atom.content, at: 8)
        try stmt.bind(encodeJSONArray(atom.tags), at: 9)
        try stmt.bind(encodeJSONArray(atom.sourceEvidenceIds), at: 10)
        try stmt.bind(iso8601(atom.validFrom), at: 11)
        try bindOptional(stmt, atom.validTo.map { iso8601($0) }, at: 12)
        try stmt.bind(iso8601(atom.createdAt), at: 13)
        try stmt.bind(iso8601(atom.updatedAt), at: 14)
        try stmt.bind(atom.confidence, at: 15)

        guard try stmt.step() else { return }
    }

    private func updateAtom(_ atom: MemoryAtom) throws {
        let stmt = try db.prepare("""
            UPDATE memory_atoms SET priority = ?, scene_name = ?, component_name = ?, content = ?, tags_json = ?, source_evidence_ids_json = ?, valid_to = ?, updated_at = ?, confidence = ? WHERE id = ?
        """)
        defer { stmt.finalize() }

        try stmt.bind(atom.priority, at: 1)
        try bindOptional(stmt, atom.sceneName, at: 2)
        try bindOptional(stmt, atom.componentName, at: 3)
        try stmt.bind(atom.content, at: 4)
        try stmt.bind(encodeJSONArray(atom.tags), at: 5)
        try stmt.bind(encodeJSONArray(atom.sourceEvidenceIds), at: 6)
        try bindOptional(stmt, atom.validTo.map { iso8601($0) }, at: 7)
        try stmt.bind(iso8601(atom.updatedAt), at: 8)
        try stmt.bind(atom.confidence, at: 9)
        try stmt.bind(atom.id, at: 10)

        guard try stmt.step() else { return }
    }

    private func insertFTS(_ atom: MemoryAtom) throws {
        let stmt = try db.prepare("""
            INSERT INTO memory_atoms_fts (id, content, tags, scene_name, component_name)
            VALUES (?, ?, ?, ?, ?)
        """)
        defer { stmt.finalize() }

        try stmt.bind(atom.id, at: 1)
        try stmt.bind(atom.content, at: 2)
        try stmt.bind(atom.tags.joined(separator: " "), at: 3)
        try bindOptional(stmt, atom.sceneName, at: 4)
        try bindOptional(stmt, atom.componentName, at: 5)

        guard try stmt.step() else { return }
    }

    private func updateFTS(_ atom: MemoryAtom) throws {
        let stmt = try db.prepare("DELETE FROM memory_atoms_fts WHERE id = ?")
        defer { stmt.finalize() }
        try stmt.bind(atom.id, at: 1)
        _ = try stmt.step()
        try insertFTS(atom)
    }

    private func searchFTS(_ query: MemoryQuery) throws -> [(MemoryAtom, String, Double)] {
        guard query.limit > 0 else { return [] }

        let nowIso = iso8601(clock.now())
        let limit = max(query.limit * 3, query.limit)
        let ftsQuery = formatFTSQuery(query.text)
        let hasText = !ftsQuery.isEmpty
        let filters = searchFilterSQL(query: query)

        let sql: String
        if hasText {
            sql = """
                SELECT a.id, a.project_id, a.type, a.scope, a.priority,
                       a.scene_name, a.component_name, a.content, a.tags_json,
                       a.source_evidence_ids_json, a.valid_from, a.valid_to,
                       a.created_at, a.updated_at, a.confidence,
                       snippet(memory_atoms_fts, 2, '<mark>', '</mark>', '...', 40), bm25(memory_atoms_fts)
                FROM memory_atoms_fts f
                JOIN memory_atoms a ON f.id = a.id
                WHERE memory_atoms_fts MATCH ?
                  AND a.project_id = ?
                  AND (a.valid_to IS NULL OR a.valid_to > ?)
                  \(filters.sql)
                ORDER BY rank
                LIMIT ?
            """

            let stmt = try db.prepare(sql)
            defer { stmt.finalize() }

            try stmt.bind(ftsQuery, at: 1)
            try stmt.bind(projectId, at: 2)
            try stmt.bind(nowIso, at: 3)
            var bindIndex: Int32 = 4
            try bindSearchFilterValues(stmt, values: filters.values, startingAt: &bindIndex)
            try stmt.bind(limit, at: bindIndex)

            var results: [(MemoryAtom, String, Double)] = []
            while try stmt.step() {
                let atom = rowToAtom(stmt)
                let snippet = stmt.columnText(15) ?? ""
                results.append((atom, snippet, -(stmt.columnDouble(16))))
            }
            return results
        } else {
            sql = """
                SELECT a.id, a.project_id, a.type, a.scope, a.priority,
                       a.scene_name, a.component_name, a.content, a.tags_json,
                       a.source_evidence_ids_json, a.valid_from, a.valid_to,
                       a.created_at, a.updated_at, a.confidence
                FROM memory_atoms a
                WHERE a.project_id = ?
                  AND (a.valid_to IS NULL OR a.valid_to > ?)
                  \(filters.sql)
                ORDER BY a.priority DESC, a.updated_at DESC
                LIMIT ?
            """

            let stmt = try db.prepare(sql)
            defer { stmt.finalize() }

            try stmt.bind(projectId, at: 1)
            try stmt.bind(nowIso, at: 2)
            var bindIndex: Int32 = 3
            try bindSearchFilterValues(stmt, values: filters.values, startingAt: &bindIndex)
            try stmt.bind(limit, at: bindIndex)

            var results: [(MemoryAtom, String, Double)] = []
            while try stmt.step() {
                let atom = rowToAtom(stmt)
                results.append((atom, "", 0))
            }
            return results
        }
    }

    private func fetchHighPriorityGlobals(query: MemoryQuery) throws -> [MemoryAtom] {
        let nowIso = iso8601(clock.now())
        let typeFilter: String
        if query.types.isEmpty {
            typeFilter = ""
        } else {
            typeFilter = " AND type IN (\(query.types.map { _ in "?" }.joined(separator: ", ")))"
        }

        let stmt = try db.prepare("""
            SELECT id, project_id, type, scope, priority, scene_name, component_name,
                   content, tags_json, source_evidence_ids_json, valid_from, valid_to,
                   created_at, updated_at, confidence
            FROM memory_atoms
            WHERE project_id = ? AND scope = 'global' AND priority >= 95
              AND (valid_to IS NULL OR valid_to > ?)
              \(typeFilter)
            ORDER BY priority DESC
        """)
        defer { stmt.finalize() }

        try stmt.bind(projectId, at: 1)
        try stmt.bind(nowIso, at: 2)
        var bindIndex: Int32 = 3
        for type in query.types {
            try stmt.bind(type.rawValue, at: bindIndex)
            bindIndex += 1
        }

        var atoms: [MemoryAtom] = []
        while try stmt.step() {
            atoms.append(rowToAtom(stmt))
        }
        return atoms
    }

    private func searchFilterSQL(query: MemoryQuery) -> (sql: String, values: [String]) {
        var clauses: [String] = []
        var values: [String] = []

        if !query.types.isEmpty {
            clauses.append("AND a.type IN (\(query.types.map { _ in "?" }.joined(separator: ", ")))")
            values.append(contentsOf: query.types.map { $0.rawValue })
        }

        if let screenName = query.screenName {
            if query.includeGlobal {
                clauses.append("AND (a.scope = 'global' OR a.scene_name = ?)")
            } else {
                clauses.append("AND a.scene_name = ?")
            }
            values.append(screenName)
        } else if !query.includeGlobal {
            clauses.append("AND a.scope != 'global'")
        }

        if let componentName = query.componentName {
            clauses.append("AND a.component_name = ?")
            values.append(componentName)
        }

        return (clauses.joined(separator: "\n"), values)
    }

    private func bindSearchFilterValues(_ stmt: Statement, values: [String], startingAt index: inout Int32) throws {
        for value in values {
            try stmt.bind(value, at: index)
            index += 1
        }
    }

    private func count(_ sql: String, value: String) throws -> Int {
        let stmt = try db.prepare(sql)
        defer { stmt.finalize() }
        try stmt.bind(value, at: 1)
        guard try stmt.step() else { return 0 }
        return stmt.columnInt(0)
    }

    private func rowToAtom(_ stmt: Statement) -> MemoryAtom {
        MemoryAtom(
            id: stmt.columnText(0) ?? "",
            projectId: stmt.columnText(1) ?? "",
            type: MemoryAtomType(rawValue: stmt.columnText(2) ?? "projectStyle") ?? .projectStyle,
            scope: MemoryScope(rawValue: stmt.columnText(3) ?? "global") ?? .global,
            priority: stmt.columnInt(4),
            sceneName: stmt.columnText(5),
            componentName: stmt.columnText(6),
            content: stmt.columnText(7) ?? "",
            tags: decodeJSONArray(stmt.columnText(8)) ?? [],
            sourceEvidenceIds: decodeJSONArray(stmt.columnText(9)) ?? [],
            validFrom: parseDate(stmt.columnText(10)) ?? Date(),
            validTo: stmt.columnText(11).flatMap { parseDate($0) },
            createdAt: parseDate(stmt.columnText(12)) ?? Date(),
            updatedAt: parseDate(stmt.columnText(13)) ?? Date(),
            confidence: stmt.columnDouble(14)
        )
    }

    private func rowToRun(_ stmt: Statement) -> RunRecord {
        RunRecord(
            id: stmt.columnText(0) ?? "",
            projectId: stmt.columnText(1) ?? "",
            sessionId: stmt.columnText(2) ?? "",
            screenName: stmt.columnText(3),
            imagePath: stmt.columnText(4) ?? "",
            model: stmt.columnText(5) ?? "",
            request: stmt.columnText(6) ?? "",
            status: stmt.columnText(7) ?? "",
            startedAt: parseDate(stmt.columnText(8)) ?? Date(),
            completedAt: stmt.columnText(9).flatMap { parseDate($0) },
            error: stmt.columnText(10),
            gdaVersion: stmt.columnText(11),
            apiVersion: stmt.columnText(12),
            promptSchemaVersion: stmt.columnText(13),
            analysisSchemaVersion: stmt.columnText(14),
            inputTokens: stmt.columnText(15).flatMap(Int.init),
            outputTokens: stmt.columnText(16).flatMap(Int.init),
            thoughtTokens: stmt.columnText(17).flatMap(Int.init),
            cachedTokens: stmt.columnText(18).flatMap(Int.init),
            totalTokens: stmt.columnText(19).flatMap(Int.init),
            durationMs: stmt.columnText(20).flatMap(Int.init),
            usageJSON: stmt.columnText(21),
            estimatedCostUSD: stmt.columnText(22).flatMap(Double.init),
            pricingVersion: stmt.columnText(23)
        )
    }

    private func normalizeContent(_ content: String) -> String {
        content.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func formatFTSQuery(_ text: String) -> String {
        let stopWords: Set<String> = ["a", "an", "and", "the", "for", "with", "this", "that", "from", "into", "of", "to", "in", "on", "at", "as", "is", "are", "be", "extract", "development", "ready", "implementation", "values"]
        let words = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !stopWords.contains($0) }
            .map { token in
                let escaped = token
                    .replacingOccurrences(of: "\"", with: "")
                    .replacingOccurrences(of: "*", with: "")
                return "\"\(escaped)\"*"
            }
        return words.joined(separator: " OR ")
    }

    private func bindOptional(_ stmt: Statement, _ value: String?, at index: Int32) throws {
        if let val = value {
            try stmt.bind(val, at: index)
        } else {
            try stmt.bindNull(at: index)
        }
    }

    private func bindOptional(_ stmt: Statement, _ value: Int?, at index: Int32) throws {
        if let value {
            try stmt.bind(value, at: index)
        } else {
            try stmt.bindNull(at: index)
        }
    }

    private func bindOptional(_ stmt: Statement, _ value: Double?, at index: Int32) throws {
        if let value {
            try stmt.bind(value, at: index)
        } else {
            try stmt.bindNull(at: index)
        }
    }

    private func encodeJSONArray(_ arr: [String]) -> String {
        guard let data = try? JSON.compactEncoder.encode(arr),
              let str = String(data: data, encoding: .utf8) else { return "[]" }
        return str
    }

    private func decodeJSONArray(_ str: String?) -> [String]? {
        guard let str = str, let data = str.data(using: .utf8) else { return nil }
        return (try? JSON.decoder.decode([String].self, from: data)) ?? []
    }

    private func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    private func parseDate(_ string: String?) -> Date? {
        guard let string = string else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: string) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string)
    }
}
