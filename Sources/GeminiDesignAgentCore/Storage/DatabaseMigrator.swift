import Foundation

public enum DatabaseMigrator {
    public static func migrate(db: SQLiteDB) throws {
        try db.exec("""
            CREATE TABLE IF NOT EXISTS schema_version (
                version INTEGER PRIMARY KEY,
                applied_at TEXT NOT NULL
            )
        """)

        let currentVersion = try db.scalarInt("SELECT COALESCE(MAX(version), 0) FROM schema_version")

        if currentVersion < 1 {
            try applyV1(db)
        }

        if currentVersion < GDAContract.databaseSchemaVersion {
            try applyV2(db)
        }
        if currentVersion < 3 {
            try applyV3(db)
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

    private static func applyV3(_ db: SQLiteDB) throws {
        try db.transaction {
            try db.exec("""
                CREATE TABLE IF NOT EXISTS memory_atom_evidence (
                    atom_id TEXT NOT NULL,
                    evidence_id TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    PRIMARY KEY (atom_id, evidence_id)
                )
            """)
            try db.exec("CREATE INDEX IF NOT EXISTS memory_atom_evidence_evidence_idx ON memory_atom_evidence(evidence_id)")
            try db.exec("INSERT INTO schema_version (version, applied_at) VALUES (3, datetime('now'))")
        }
    }
}
