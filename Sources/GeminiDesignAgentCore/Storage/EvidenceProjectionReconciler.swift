import Foundation

enum EvidenceProjectionReconciler {
    static func refreshLegacyJSONProjection(db: SQLiteDB, projectId: String? = nil) throws {
        let suffix = projectId == nil ? "" : " WHERE project_id = ?"
        let statement = try db.prepare("""
            UPDATE memory_atoms
            SET source_evidence_ids_json = COALESCE(
                (
                    SELECT json_group_array(evidence_id)
                    FROM (
                        SELECT evidence_id
                        FROM memory_atom_evidence
                        WHERE atom_id = memory_atoms.id
                        ORDER BY evidence_id
                    )
                ),
                '[]'
            )
            \(suffix)
        """)
        defer { statement.finalize() }
        if let projectId {
            try statement.bind(projectId, at: 1)
        }
        _ = try statement.step()
    }
}
