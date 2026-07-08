import Foundation
import ArgumentParser
import AsyncHTTPClient
import GeminiDesignAgentCore

@main
struct GDA: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gda",
        abstract: "Gemini Design Agent - analyze UI screenshots with Gemini vision and layered design memory",
        subcommands: [
            InitCommand.self,
            AnalyzeCommand.self,
            MemoryCommand.self,
            CompactCommand.self,
            ResetCommand.self
        ]
    )
}

enum CLIUtils {
    static func loadAPIClient(apiKey: String? = nil, timeoutSeconds: Int = 120) throws -> GeminiVisionClient {
        let key = apiKey ?? ProcessInfo.processInfo.environment["GEMINI_API_KEY"] ?? ""
        if key.isEmpty {
            throw GeminiError.apiKeyMissing
        }
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

    static func shutdownHTTPClient() async {
        try? await HTTPClient.shared.shutdown()
    }
}

struct CLIError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct InitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Initialize a new design memory project"
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
            CLIUtils.printJSON([
                "ok": true,
                "project_id": projectId,
                "project_dir": projectDir,
                "database_path": paths.dbPath.path
            ])
        } else {
            print("Project initialized: \(projectName)")
            print("  Project ID: \(projectId)")
            print("  Directory:  \(projectDir)")
        }
    }
}
