import Foundation
import ArgumentParser
import GeminiDesignAgentCore

struct CompactCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compact",
        abstract: "Compact and rebuild design memory scene/profile summaries"
    )

    @Option(name: .long, help: "Project directory path")
    var projectDir: String = ".gda"

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }

        let (context, paths, db) = try CLIUtils.loadOrInitProject(projectDir: projectDir)
        let memory = try SQLiteMemoryStore(db: db, projectId: context.projectId, recordsDir: paths.recordsDir)
        let stats = try await memory.stats()

        Logger.info("Inspecting memory for project \(context.projectId)...")

        if json {
            let output: [String: Any] = [
                "ok": true,
                "project_id": context.projectId,
                "atom_count": stats.atomCount,
                "scene_count": stats.sceneCount,
                "has_project_profile": stats.hasProjectProfile,
                "message": "Scene and profile summaries are updated after each analyze run."
            ]
            CLIUtils.printJSON(output)
        } else {
            print("Memory status for project \(context.projectId)")
            print("  Atoms: \(stats.atomCount)")
            print("  Scenes: \(stats.sceneCount)")
            print("  Project profile: \(stats.hasProjectProfile ? "present" : "missing")")
            print("Scene blocks and project profiles are updated after each analysis.")
        }
    }
}
