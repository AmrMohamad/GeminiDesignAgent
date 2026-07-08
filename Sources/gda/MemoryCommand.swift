import Foundation
import ArgumentParser
import GeminiDesignAgentCore

struct MemoryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "memory",
        abstract: "Manage design memory",
        discussion: """
        Examples:
          gda memory search --query "primary button" --json
          gda memory show --id mem_123 --json
          gda memory preview --screen Home --request "primary button" --json
          gda memory explain --run-id run_123 --json
          gda memory conflicts --json
          gda memory export --json
        """,
        subcommands: [
            MemorySearchCommand.self,
            MemoryShowCommand.self,
            MemoryPreviewCommand.self,
            MemoryExplainCommand.self,
            MemoryConflictsCommand.self,
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
            CLIResponse.success(
                command: "memory.search",
                data: [
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
                ],
                nextActions: [["label": "Inspect atom", "command": "gda memory show --project-dir \(projectDir) --id <atom-id> --json"]]
            )
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
            let error = CLIError(
                code: "MEMORY_ATOM_NOT_FOUND",
                title: "Memory atom was not found",
                message: "Memory atom not found: \(id)",
                resolution: "Run `gda memory search --json` to find valid memory atom IDs.",
                retryable: false,
                suggestedCommand: "gda memory search --project-dir \(projectDir) --query \"\" --json",
                exitCode: 1
            )
            if json { CLIResponse.failure(command: "memory.show", error: error) } else { print("Not found: \(id)") }
            throw ExitCode(1)
        }

        if json {
            try CLIResponse.successEncodable(command: "memory.show", data: atom)
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

        if json {
            CLIResponse.success(
                command: "memory.export",
                data: ["atoms": try CLIResponse.object(from: atoms)]
            )
        } else {
            let data = try JSON.encoder.encode(atoms)
            if let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        }
    }
}

struct MemoryConflictsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "conflicts",
        abstract: "Surface obvious contradictory memory atoms"
    )

    @Option(name: .long, help: "Project directory path")
    var projectDir: String = ".gda"

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }

        do {
            let (context, paths, db) = try CLIUtils.loadOrInitProject(projectDir: projectDir)
            let memory = try SQLiteMemoryStore(db: db, projectId: context.projectId, recordsDir: paths.recordsDir)
            let atoms = try memory.activeAtoms()
            let conflicts = findColorConflicts(atoms)

            if json {
                CLIResponse.success(
                    command: "memory.conflicts",
                    data: ["conflicts": conflicts, "conflict_count": conflicts.count]
                )
            } else {
                if conflicts.isEmpty {
                    print("No obvious color conflicts found.")
                } else {
                    for conflict in conflicts {
                        print("\(conflict["group"] ?? "group"): \(conflict["hex_values"] ?? [])")
                    }
                }
            }
        } catch {
            if json { CLIResponse.failure(command: "memory.conflicts", error: error) } else { print("Error: \(error.localizedDescription)") }
            throw ExitCode(1)
        }
    }

    private func findColorConflicts(_ atoms: [MemoryAtom]) -> [[String: Any]] {
        var groups: [String: [(atom: MemoryAtom, hexes: [String])]] = [:]
        for atom in atoms {
            let hexes = hexValues(in: atom.content)
            guard !hexes.isEmpty else { continue }
            let group = [
                atom.type.rawValue,
                atom.scope.rawValue,
                atom.sceneName ?? "global",
                atom.componentName ?? "none",
                normalizedColorSubject(atom.content)
            ].joined(separator: "|")
            groups[group, default: []].append((atom, hexes))
        }

        return groups.compactMap { key, values in
            let uniqueHexes = Array(Set(values.flatMap(\.hexes))).sorted()
            guard uniqueHexes.count > 1 else { return nil }
            return [
                "group": key,
                "hex_values": uniqueHexes,
                "atom_ids": values.map { $0.atom.id },
                "contents": values.map { $0.atom.content }
            ]
        }.sorted { lhs, rhs in
            String(describing: lhs["group"] ?? "") < String(describing: rhs["group"] ?? "")
        }
    }

    private func hexValues(in content: String) -> [String] {
        let pattern = "#[0-9A-Fa-f]{6}\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        return regex.matches(in: content, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: content) else { return nil }
            return content[swiftRange].uppercased()
        }
    }

    private func normalizedColorSubject(_ content: String) -> String {
        content
            .replacingOccurrences(of: "#[0-9A-Fa-f]{6}\\b", with: "#HEX", options: .regularExpression)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct MemoryPreviewCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "preview",
        abstract: "Preview memory that would be injected for a screen and request"
    )

    @Option(name: .long, help: "Project directory path")
    var projectDir: String = ".gda"

    @Option(name: .long, help: "Screen name")
    var screen: String

    @Option(name: .long, help: "Analysis request")
    var request: String

    @Option(name: .long, help: "Maximum memory atoms")
    var limit: Int = 8

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }

        do {
            let (context, paths, db) = try CLIUtils.loadOrInitProject(projectDir: projectDir)
            let memory = try SQLiteMemoryStore(db: db, projectId: context.projectId, recordsDir: paths.recordsDir)
            let injection = try await MemoryInjectionBuilder(memory: memory).build(
                screenName: screen,
                request: request,
                limit: limit
            )

            if json {
                CLIResponse.success(
                    command: "memory.preview",
                    data: previewPayload(injection: injection, screen: screen, request: request)
                )
            } else {
                print("Memory preview for \(screen)")
                for result in injection.atoms {
                    print("  \(result.atom.id) score:\(result.score) \(result.atom.content)")
                }
            }
        } catch {
            if json { CLIResponse.failure(command: "memory.preview", error: error) } else { print("Error: \(error.localizedDescription)") }
            throw ExitCode(1)
        }
    }
}

struct MemoryExplainCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "explain",
        abstract: "Explain memory injection for a saved run"
    )

    @Option(name: .long, help: "Project directory path")
    var projectDir: String = ".gda"

    @Option(name: .long, help: "Run ID")
    var runId: String

    @Option(name: .long, help: "Maximum memory atoms")
    var limit: Int = 8

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }

        do {
            let (context, paths, db) = try CLIUtils.loadOrInitProject(projectDir: projectDir)
            let memory = try SQLiteMemoryStore(db: db, projectId: context.projectId, recordsDir: paths.recordsDir)

            guard let run = try memory.getRun(id: runId) else {
                let error = CLIError(
                    code: "RUN_NOT_FOUND",
                    title: "Run was not found",
                    message: "Run not found: \(runId)",
                    resolution: "Run `gda runs list --json` to find recent run IDs.",
                    retryable: false,
                    suggestedCommand: "gda runs list --project-dir \(projectDir) --json",
                    exitCode: 1
                )
                if json { CLIResponse.failure(command: "memory.explain", error: error) } else { print("Run not found: \(runId)") }
                throw ExitCode(1)
            }

            let screen = run.screenName ?? ""
            let injection = try await MemoryInjectionBuilder(memory: memory).build(
                screenName: screen,
                request: run.request,
                limit: limit
            )

            if json {
                var payload = previewPayload(injection: injection, screen: screen, request: run.request)
                payload["run_id"] = run.id
                payload["run_status"] = run.status
                CLIResponse.success(command: "memory.explain", data: payload)
            } else {
                print("Memory explanation for \(run.id) [\(run.status)]")
                for result in injection.atoms {
                    print("  \(result.atom.id) score:\(result.score) \(result.atom.content)")
                }
            }
        } catch let exit as ExitCode {
            throw exit
        } catch {
            if json { CLIResponse.failure(command: "memory.explain", error: error) } else { print("Error: \(error.localizedDescription)") }
            throw ExitCode(1)
        }
    }
}

private func previewPayload(injection: MemoryInjection, screen: String, request: String) -> [String: Any] {
    [
        "screen": screen,
        "request": request,
        "profile_used": injection.projectProfile != nil,
        "scene_used": injection.sceneBlock != nil,
        "scene_id": injection.sceneBlock?.id ?? NSNull(),
        "atom_count": injection.atoms.count,
        "atoms": injection.atoms.map { result in
            [
                "id": result.atom.id,
                "type": result.atom.type.rawValue,
                "scope": result.atom.scope.rawValue,
                "priority": result.atom.priority,
                "score": result.score,
                "content": result.atom.content,
                "sceneName": result.atom.sceneName ?? "",
                "componentName": result.atom.componentName ?? "",
                "reason": memoryReason(result)
            ] as [String: Any]
        },
        "canvas": injection.canvas
    ]
}

private func memoryReason(_ result: MemorySearchResult) -> String {
    var reasons: [String] = []
    if result.atom.scope == .global {
        reasons.append("global scope")
    }
    if result.atom.priority >= 90 {
        reasons.append("high priority")
    }
    if result.score > 0 {
        reasons.append("ranked match")
    }
    if let scene = result.atom.sceneName, !scene.isEmpty {
        reasons.append("scene \(scene)")
    }
    return reasons.isEmpty ? "retrieved by memory search" : reasons.joined(separator: ", ")
}
