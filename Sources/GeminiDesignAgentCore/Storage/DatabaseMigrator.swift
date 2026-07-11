import Foundation

public enum DatabaseMigrator {
    public static func migrate(db: SQLiteDB) throws {
        try db.exec("""
            CREATE TABLE IF NOT EXISTS schema_version (
                version INTEGER PRIMARY KEY,
                applied_at TEXT NOT NULL
            )
        """)

        let originalVersion = try db.scalarInt("SELECT COALESCE(MAX(version), 0) FROM schema_version")

        if originalVersion < 1 {
            try applyV1(db)
        }

        if originalVersion < 2 {
            try applyV2(db)
        }
        if originalVersion < 3 {
            try applyV3AndBackfillLegacyJSON(db)
        } else {
            try ensureV3Tables(db)
            try reconcileLegacyV3IfNeeded(db)
        }
    }

    private static func applyV1(_ db: SQLiteDB) throws {
        try db.exec("""
            CREATE TABLE IF NOT EXISTS evidence_records (
                id TEXT PRIMARY KEY,
                run_id TEXT NOT NULL,
                project_id TEXT NOT NULL,
                session_id TEXT NOT NULL,
                screen_name TEXT,
                kind TEXT NOT NULL,
                content_path TEXT NOT NULL,
                summary TEXT,
                created_at TEXT NOT NULL
            )
        """)

        try db.exec("""
            CREATE TABLE IF NOT EXISTS memory_atoms (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                type TEXT NOT NULL,
                scope TEXT NOT NULL,
                priority INTEGER NOT NULL,
                scene_name TEXT,
                component_name TEXT,
                content TEXT NOT NULL,
                tags_json TEXT NOT NULL,
                source_evidence_ids_json TEXT NOT NULL,
                valid_from TEXT NOT NULL,
                valid_to TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                confidence REAL NOT NULL
            )
        """)

        try db.exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS memory_atoms_fts
            USING fts5(
                id UNINDEXED,
                content,
                tags,
                scene_name,
                component_name,
                tokenize = 'unicode61'
            )
        """)

        try db.exec("""
            CREATE TABLE IF NOT EXISTS scene_blocks (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                name TEXT NOT NULL,
                summary TEXT NOT NULL,
                key_components_json TEXT NOT NULL,
                key_tokens_json TEXT NOT NULL,
                memory_atom_ids_json TEXT NOT NULL,
                evidence_ids_json TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                UNIQUE(project_id, name)
            )
        """)

        try db.exec("""
            CREATE TABLE IF NOT EXISTS project_profiles (
                project_id TEXT PRIMARY KEY,
                project_name TEXT NOT NULL,
                profile_json TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
        """)

        try db.exec("""
            CREATE TABLE IF NOT EXISTS runs (
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
            INSERT INTO schema_version (version, applied_at)
            VALUES (1, datetime('now'))
        """)
    }

    private static func applyV2(_ db: SQLiteDB) throws {
        try db.transaction {
            try db.exec("ALTER TABLE runs ADD COLUMN gda_version TEXT")
            try db.exec("ALTER TABLE runs ADD COLUMN api_version TEXT")
            try db.exec("ALTER TABLE runs ADD COLUMN prompt_schema_version TEXT")
            try db.exec("ALTER TABLE runs ADD COLUMN analysis_schema_version TEXT")
            try db.exec("ALTER TABLE runs ADD COLUMN input_tokens INTEGER")
            try db.exec("ALTER TABLE runs ADD COLUMN output_tokens INTEGER")
            try db.exec("ALTER TABLE runs ADD COLUMN thought_tokens INTEGER")
            try db.exec("ALTER TABLE runs ADD COLUMN cached_tokens INTEGER")
            try db.exec("ALTER TABLE runs ADD COLUMN total_tokens INTEGER")
            try db.exec("ALTER TABLE runs ADD COLUMN duration_ms INTEGER")
            try db.exec("ALTER TABLE runs ADD COLUMN usage_json TEXT")
            try db.exec("ALTER TABLE runs ADD COLUMN estimated_cost_usd REAL")
            try db.exec("ALTER TABLE runs ADD COLUMN pricing_version TEXT")
            try db.exec("""
                INSERT INTO schema_version (version, applied_at)
                VALUES (2, datetime('now'))
            """)
        }
    }

    private static func applyV3AndBackfillLegacyJSON(_ db: SQLiteDB) throws {
        try db.transaction {
            try ensureV3Tables(db)
            if try hasTable(named: "memory_atoms", db: db) {
                try backfillEvidenceLinksFromLegacyJSON(db)
                try EvidenceProjectionReconciler.refreshLegacyJSONProjection(db: db)
            }
            try markEvidenceBackfillComplete(db)
            try db.exec("INSERT INTO schema_version (version, applied_at) VALUES (3, datetime('now'))")
        }
    }

    private static func reconcileLegacyV3IfNeeded(_ db: SQLiteDB) throws {
        guard try db.scalar("SELECT name FROM migration_backfills WHERE name = 'memory_atom_evidence_v3'") == nil else {
            return
        }
        try db.transaction {
            if try hasTable(named: "memory_atoms", db: db) {
                try EvidenceProjectionReconciler.refreshLegacyJSONProjection(db: db)
            }
            try markEvidenceBackfillComplete(db)
        }
    }

    private static func hasTable(named name: String, db: SQLiteDB) throws -> Bool {
        let statement = try db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?")
        defer { statement.finalize() }
        try statement.bind(name, at: 1)
        return try statement.step()
    }

    private static func backfillEvidenceLinksFromLegacyJSON(_ db: SQLiteDB) throws {
        let atoms = try db.prepare("SELECT id, source_evidence_ids_json, created_at FROM memory_atoms")
        defer { atoms.finalize() }
        let link = try db.prepare("INSERT OR IGNORE INTO memory_atom_evidence(atom_id, evidence_id, created_at) VALUES (?, ?, ?)")
        defer { link.finalize() }

        while try atoms.step() {
            guard let atomID = atoms.columnText(0) else { continue }
            let evidenceIDs = decodeEvidenceIDs(atoms.columnText(1))
            let createdAt = atoms.columnText(2) ?? "1970-01-01T00:00:00Z"
            for evidenceID in evidenceIDs {
                try link.bind(atomID, at: 1)
                try link.bind(evidenceID, at: 2)
                try link.bind(createdAt, at: 3)
                _ = try link.step()
                try link.reset()
            }
        }
    }

    private static func decodeEvidenceIDs(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Array(Set(ids.filter { !$0.isEmpty })).sorted()
    }

    private static func markEvidenceBackfillComplete(_ db: SQLiteDB) throws {
        try db.exec("INSERT INTO migration_backfills(name, completed_at) VALUES ('memory_atom_evidence_v3', datetime('now'))")
    }

    private static func ensureV3Tables(_ db: SQLiteDB) throws {
        try db.exec("""
                CREATE TABLE IF NOT EXISTS memory_atom_evidence (
                    atom_id TEXT NOT NULL,
                    evidence_id TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    PRIMARY KEY (atom_id, evidence_id)
                )
            """)
        try db.exec("CREATE INDEX IF NOT EXISTS memory_atom_evidence_evidence_idx ON memory_atom_evidence(evidence_id)")
        try db.exec("""
                CREATE TABLE IF NOT EXISTS migration_backfills (
                    name TEXT PRIMARY KEY,
                    completed_at TEXT NOT NULL
                )
            """)
    }
}
