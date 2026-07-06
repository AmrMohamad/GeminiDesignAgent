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

        let (context, _, _) = try CLIUtils.loadOrInitProject(projectDir: projectDir)

        Logger.info("Compacting memory for project \(context.projectId)...")

        if json {
            let output: [String: Any] = [
                "ok": true,
                "message": "Memory compaction requested. Use gda analyze to update scene/profile from Gemini."
            ]
            CLIUtils.printJSON(output)
        } else {
            print("Memory compaction requested.")
            print("Scene blocks and project profiles are auto-updated after each analysis.")
            print("For deeper compaction with Gemini, use gda analyze on key screens.")
        }
    }
}
