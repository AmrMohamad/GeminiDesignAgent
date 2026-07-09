import Foundation
import ArgumentParser
import GeminiDesignAgentCore
import GDAPlatformSupport

@main
struct GDA: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gda",
        abstract: "Gemini Design Agent - analyze UI screenshots with Gemini vision and layered design memory",
        subcommands: [
            SetupCommand.self,
            InitCommand.self,
            AnalyzeCommand.self,
            CompareCommand.self,
            DoctorCommand.self,
            LockCommand.self,
            AuthCommand.self,
            MemoryCommand.self,
            RunsCommand.self,
            ExportCommand.self,
            SnapshotCommand.self,
            CompactCommand.self,
            GCCommand.self,
            ResetCommand.self
        ]
    )
}

enum CLIUtils {
    static func loadAPIClient(
        apiKey: String? = nil,
        timeoutSeconds: Int = 120,
        apiKeyStore: APIKeyStore = KeychainAPIKeyStore()
    ) throws -> GeminiVisionClient {
        let key = try APIKeyResolver.resolve(apiKey: apiKey, store: apiKeyStore)
        return GeminiVisionClient(apiKey: key, timeoutSeconds: timeoutSeconds)
    }

    static func loadOrInitProject(projectDir: String, projectName: String = "Design Project") throws -> (RuntimeContext, ArtifactPaths, SQLiteDB) {
        let dirURL = URL(fileURLWithPath: projectDir, isDirectory: true)
        let paths = ArtifactPaths(projectDir: dirURL)

        if !FileManager.default.fileExists(atPath: paths.configPath.path) {
            try paths.ensureDirectories()
            let db = try SQLiteDB(path: paths.dbPath.path)
            try DatabaseMigrator.migrate(db: db)

            let projectId = StableID.project()
            let configData = try JSONSerialization.data(withJSONObject: [
                "project_id": projectId,
                "project_name": projectName,
                "created_at": ISO8601DateFormatter().string(from: Date())
            ], options: .sortedKeys)
            try configData.write(to: paths.configPath)
            Logger.info("Auto-initialized project at \(projectDir)")
        }

        let configData = try Data(contentsOf: paths.configPath)
        guard let configJSON = try JSONSerialization.jsonObject(with: configData) as? [String: Any],
              let projectId = configJSON["project_id"] as? String else {
            throw CLIError("Invalid config.json in \(projectDir)")
        }

        let projectNameLoaded = configJSON["project_name"] as? String ?? projectName

        let context = RuntimeContext(
            projectId: projectId,
            projectName: projectNameLoaded,
            projectDir: projectDir
        )

        let db = try SQLiteDB(path: paths.dbPath.path)
        try DatabaseMigrator.migrate(db: db)

        return (context, paths, db)
    }

    static func printJSON(_ value: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]),
              let str = String(data: data, encoding: .utf8) else {
            print("{}")
            return
        }
        print(str)
    }

    static func shutdownHTTPClient() async {}
}

struct InitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Initialize a new design memory project",
        discussion: """
        Examples:
          gda init --project-dir .gda --project-name "iOS App"
          gda init --json
          gda doctor --project-dir .gda --json
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

        let dirURL = URL(fileURLWithPath: projectDir, isDirectory: true)
        let paths = ArtifactPaths(projectDir: dirURL)

        try paths.ensureDirectories()

        let db = try SQLiteDB(path: paths.dbPath.path)
        try DatabaseMigrator.migrate(db: db)

        let projectId = StableID.project()

        let configData = try JSONSerialization.data(withJSONObject: [
            "project_id": projectId,
            "project_name": projectName,
            "created_at": ISO8601DateFormatter().string(from: Date())
        ], options: .sortedKeys)
        try configData.write(to: paths.configPath)

        if json {
            CLIResponse.success(
                command: "init",
                data: [
                    "project_id": projectId,
                    "project_dir": projectDir,
                    "database_path": paths.dbPath.path
                ],
                nextActions: [
                    ["label": "Check project health", "command": "gda doctor --project-dir \(projectDir) --json"],
                    ["label": "Analyze a screenshot", "command": "gda analyze --project-dir \(projectDir) --image screen.png --screen Home --json"]
                ]
            )
        } else {
            print("Project initialized: \(projectName)")
            print("  Project ID: \(projectId)")
            print("  Directory:  \(projectDir)")
        }
    }
}
