import Foundation
import ArgumentParser
import GeminiDesignAgentCore

struct MemoryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "memory",
        abstract: "Manage design memory",
        subcommands: [
            MemorySearchCommand.self,
            MemoryShowCommand.self,
            MemoryExportCommand.self
        ]
    )
}

struct MemorySearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search design memory atoms"
    )

    @Option(name: .long, help: "Project directory path")
    var projectDir: String = ".gda"

    @Option(name: .long, help: "Search query")
    var query: String

    @Option(name: .long, help: "Maximum results")
    var limit: Int = 8

    @Option(name: .long, help: "Filter by atom type")
    var type: String?

    @Option(name: .long, help: "Filter by screen name")
    var screenName: String?

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }

        let (context, paths, db) = try CLIUtils.loadOrInitProject(projectDir: projectDir)
        let memory = try SQLiteMemoryStore(db: db, projectId: context.projectId, recordsDir: paths.recordsDir)

        var types: [MemoryAtomType] = []
        if let typeStr = type {
            if let t = MemoryAtomType(rawValue: typeStr) {
                types = [t]
            }
        }

        let queryObj = MemoryQuery(
            text: query,
            limit: limit,
            types: types,
            screenName: screenName,
            includeGlobal: true
        )

        let results = try await memory.searchAtoms(queryObj)

        if json {
            let output: [String: Any] = [
                "ok": true,
                "results": results.map { r in
                    [
                        "id": r.atom.id,
                        "type": r.atom.type.rawValue,
                        "scope": r.atom.scope.rawValue,
                        "priority": r.atom.priority,
                        "content": r.atom.content,
                        "tags": r.atom.tags,
                        "score": r.score,
                        "snippet": r.matchSnippet ?? "",
                        "sceneName": r.atom.sceneName ?? "",
                        "componentName": r.atom.componentName ?? ""
                    ] as [String: Any]
                }
            ]
            CLIUtils.printJSON(output)
        } else {
            for result in results {
                print("[\(result.atom.type.rawValue)/\(result.atom.scope.rawValue)] priority:\(result.atom.priority) \(result.atom.content)")
                if let snippet = result.matchSnippet, !snippet.isEmpty {
                    print("  snippet: \(snippet)")
                }
                print("")
            }
        }
    }
}

struct MemoryShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show a specific memory atom"
    )

    @Option(name: .long, help: "Project directory path")
    var projectDir: String = ".gda"

    @Option(name: .long, help: "Memory atom ID")
    var id: String

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }

        let (context, paths, db) = try CLIUtils.loadOrInitProject(projectDir: projectDir)
        let memory = try SQLiteMemoryStore(db: db, projectId: context.projectId, recordsDir: paths.recordsDir)

        guard let atom = try await memory.getAtom(id: id) else {
            let error: [String: Any] = ["ok": false, "error": ["code": "NOT_FOUND", "message": "Memory atom not found: \(id)"]]
            if json { CLIUtils.printJSON(error) } else { print("Not found: \(id)") }
            throw ExitCode(1)
        }

        if json {
            let data = try JSON.encoder.encode(atom)
            if let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        } else {
            print("ID: \(atom.id)")
            print("Type: \(atom.type.rawValue)")
            print("Scope: \(atom.scope.rawValue)")
            print("Priority: \(atom.priority)")
            print("Scene: \(atom.sceneName ?? "none")")
            print("Component: \(atom.componentName ?? "none")")
            print("Content: \(atom.content)")
            print("Tags: \(atom.tags.joined(separator: ", "))")
            print("Confidence: \(atom.confidence)")
            print("Source evidence: \(atom.sourceEvidenceIds.joined(separator: ", "))")
        }
    }
}

struct MemoryExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export all memory atoms as JSON"
    )

    @Option(name: .long, help: "Project directory path")
    var projectDir: String = ".gda"

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }

        let (context, paths, db) = try CLIUtils.loadOrInitProject(projectDir: projectDir)
        let memory = try SQLiteMemoryStore(db: db, projectId: context.projectId, recordsDir: paths.recordsDir)

        let results = try await memory.searchAtoms(MemoryQuery(
            text: "",
            limit: 1000,
            includeGlobal: true
        ))

        let atoms = results.map { $0.atom }

        let data = try JSON.encoder.encode(atoms)
        if let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }
}
