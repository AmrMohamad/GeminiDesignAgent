import Foundation
import ArgumentParser
import GeminiDesignAgentCore

struct ResetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reset",
        abstract: "Reset project memory (requires confirmation)",
        discussion: """
        Examples:
          gda reset --project-dir .gda
          gda reset --project-dir .gda --confirm --json
        """
    )

    @Option(name: .long, help: "Project directory path")
    var projectDir: String = ".gda"

    @Flag(name: .long, help: "Skip confirmation prompt")
    var confirm: Bool = false

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }

        let dirURL = URL(fileURLWithPath: projectDir, isDirectory: true)

        guard FileManager.default.fileExists(atPath: dirURL.path) else {
            let error = CLIError(
                code: "PROJECT_NOT_FOUND",
                title: "Project directory was not found",
                message: "Project directory not found: \(projectDir)",
                resolution: "Pass an existing `--project-dir`, or run `gda init` first.",
                retryable: false,
                suggestedCommand: "gda init --project-dir \(projectDir)",
                exitCode: 1
            )
            if json { CLIResponse.failure(command: "reset", error: error) } else { print(error.message) }
            throw ExitCode(1)
        }

        if !confirm {
            if json {
                let error = CLIError(
                    code: "CONFIRMATION_REQUIRED",
                    title: "Reset requires explicit confirmation",
                    message: "`gda reset --json` does not prompt because JSON stdout must stay machine-readable.",
                    resolution: "Rerun with `--confirm --json` if you intentionally want to delete the project memory.",
                    retryable: false,
                    suggestedCommand: "gda reset --project-dir \(projectDir) --confirm --json",
                    exitCode: 2
                )
                CLIResponse.failure(command: "reset", error: error)
                throw ExitCode(2)
            }
            print("WARNING: This will delete all design memory in \(projectDir)")
            print("Type 'yes' to confirm: ", terminator: "")
            guard let input = readLine(), input.lowercased() == "yes" else {
                print("Cancelled.")
                return
            }
        }

        try FileManager.default.removeItem(at: dirURL)

        if json {
            CLIResponse.success(
                command: "reset",
                data: ["message": "Project memory reset successfully", "project_dir": projectDir],
                nextActions: [["label": "Initialize project", "command": "gda init --project-dir \(projectDir) --json"]]
            )
        } else {
            print("Project memory reset successfully.")
        }
    }
}
