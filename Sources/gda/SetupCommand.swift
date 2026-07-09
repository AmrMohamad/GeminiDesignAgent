import Foundation
import ArgumentParser
import GeminiDesignAgentCore
import GDAPlatformSupport

struct SetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Initialize a project and show the next safe commands",
        discussion: """
        Examples:
          gda setup --project-dir .gda --project-name "iOS App" --json
          gda setup --project-dir .gda
        """
    )

    @Option(name: .long, help: "Project directory path")
    var projectDir: String = ".gda"

    @Option(name: .long, help: "Project name")
    var projectName: String = "Design Project"

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }

        do {
            let (context, paths, _) = try CLIUtils.loadOrInitProject(projectDir: projectDir, projectName: projectName)
            let authConfigured = (try? KeychainAPIKeyStore().load()) != nil
            let data: [String: Any] = [
                "project_id": context.projectId,
                "project_name": context.projectName,
                "project_dir": paths.rootDir.path,
                "auth_configured": authConfigured
            ]
            let nextActions: [[String: Any]] = [
                authConfigured ? [:] : ["label": "Start auth onboarding", "command": "gda auth onboard"],
                ["label": "Run preflight", "command": "gda doctor --project-dir \(projectDir) --json"],
                ["label": "Analyze a screenshot", "command": "gda analyze --project-dir \(projectDir) --image screen.png --screen Home --json"]
            ].filter { !$0.isEmpty }

            if json {
                CLIResponse.success(command: "setup", data: data, nextActions: nextActions)
            } else {
                print("Project ready: \(context.projectName)")
                print("  Directory: \(paths.rootDir.path)")
                print(authConfigured ? "  Auth: configured" : "  Auth: not configured. Run `gda auth onboard`.")
                print("Next: gda doctor --project-dir \(projectDir)")
            }
        } catch {
            if json { CLIResponse.failure(command: "setup", error: error) } else { print("Error: \(error.localizedDescription)") }
            throw ExitCode(1)
        }
    }
}
