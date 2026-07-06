import Foundation
import ArgumentParser
import GeminiDesignAgentCore

struct ResetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reset",
        abstract: "Reset project memory (requires confirmation)"
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
            let error: [String: Any] = ["ok": false, "error": ["code": "NOT_FOUND", "message": "Project directory not found: \(projectDir)"]]
            if json { CLIUtils.printJSON(error) } else { print("Project directory not found: \(projectDir)") }
            throw ExitCode(1)
        }

        if !confirm {
            print("WARNING: This will delete all design memory in \(projectDir)")
            print("Type 'yes' to confirm: ", terminator: "")
            guard let input = readLine(), input.lowercased() == "yes" else {
                print("Cancelled.")
                return
            }
        }

        try FileManager.default.removeItem(at: dirURL)

        if json {
            CLIUtils.printJSON(["ok": true, "message": "Project memory reset successfully"])
        } else {
            print("Project memory reset successfully.")
        }
    }
}
