import Foundation
import ArgumentParser
import GeminiDesignAgentCore

struct RunsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "runs",
        abstract: "Inspect analyze run history and artifacts",
        discussion: """
        Examples:
          gda runs list --project-dir .gda --json
          gda runs show --project-dir .gda --id run_123 --json
          gda runs stats --project-dir .gda --since-days 30 --json
        """,
        subcommands: [
            RunsListCommand.self,
            RunsStatsCommand.self,
            RunsShowCommand.self,
            RunsUndoCommand.self,
            RunsRecoverCommand.self
        ]
    )
}

struct RunsStatsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stats",
        abstract: "Summarize analyze usage, latency, and upper-bound estimated cost"
    )

    @Option(name: .long, help: "Project directory path")
    var projectDir: String = ".gda"

    @Option(name: .long, help: "Number of trailing days to include")
    var sinceDays: Int = 30

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }

        guard sinceDays > 0 else {
            let error = CLIError(
                code: "INVALID_TIME_WINDOW",
                title: "Time window is invalid",
                message: "`--since-days` must be greater than zero.",
                resolution: "Pass a positive day count, for example `--since-days 30`.",
                retryable: false,
                exitCode: 2
            )
            if json { CLIResponse.failure(command: "runs.stats", error: error) } else { print("Error: \(error.message)") }
            throw ExitCode(2)
        }

        do {
            let now = Date()
            let since = now.addingTimeInterval(-Double(sinceDays) * 86_400)
            let (context, paths, db) = try CLIUtils.loadOrInitProject(projectDir: projectDir)
            let memory = try SQLiteMemoryStore(db: db, projectId: context.projectId, recordsDir: paths.recordsDir)
            let statistics = try memory.runStatistics(since: since, requestedSinceDays: sinceDays, generatedAt: now)

            if json {
                try CLIResponse.successEncodable(command: "runs.stats", data: statistics)
            } else {
                print("Runs: \(statistics.totalRuns) (\(statistics.completedRuns) completed, \(statistics.failedRuns) failed)")
                print("Tokens: \(statistics.totalTokens)")
                print("Upper-bound estimated cost: $\(String(format: "%.6f", statistics.upperBoundEstimatedCostUSD))")
                if let averageDurationMs = statistics.averageDurationMs {
                    print("Average duration: \(Int(averageDurationMs.rounded())) ms")
                }
                if statistics.unpricedRuns > 0 {
                    print("Unpriced runs: \(statistics.unpricedRuns)")
                }
            }
        } catch let exit as ExitCode {
            throw exit
        } catch {
            if json { CLIResponse.failure(command: "runs.stats", error: error) } else { print("Error: \(error.localizedDescription)") }
            throw ExitCode(1)
        }
    }
}

struct RunsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List recent analyze runs"
    )

    @Option(name: .long, help: "Project directory path")
    var projectDir: String = ".gda"

    @Option(name: .long, help: "Maximum runs to return")
    var limit: Int = 25

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }

        do {
            let (context, paths, db) = try CLIUtils.loadOrInitProject(projectDir: projectDir)
            let memory = try SQLiteMemoryStore(db: db, projectId: context.projectId, recordsDir: paths.recordsDir)
            let runs = try memory.listRuns(limit: limit)

            if json {
                try CLIResponse.successEncodable(
                    command: "runs.list",
                    data: ["runs": runs]
                )
            } else {
                for run in runs {
                    print("\(run.id) [\(run.status)] \(run.screenName ?? "unknown") \(run.startedAt)")
                }
            }
        } catch {
            if json { CLIResponse.failure(command: "runs.list", error: error) } else { print("Error: \(error.localizedDescription)") }
            throw ExitCode(1)
        }
    }
}

struct RunsUndoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "undo",
        abstract: "Expire memory atoms written from a run"
    )

    @Option(name: .long, help: "Project directory path")
    var projectDir: String = ".gda"

    @Option(name: .long, help: "Run ID")
    var id: String

    @Flag(name: .long, help: "Confirm undo")
    var confirm: Bool = false

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }

        guard confirm else {
            let error = CLIError(
                code: "CONFIRMATION_REQUIRED",
                title: "Undo requires explicit confirmation",
                message: "`gda runs undo` expires memory atoms written from a run.",
                resolution: "Rerun with `--confirm` if this is intentional.",
                retryable: false,
                suggestedCommand: "gda runs undo --project-dir \(projectDir) --id \(id) --confirm --json",
                exitCode: 2
            )
            if json { CLIResponse.failure(command: "runs.undo", error: error) } else { print(error.message) }
            throw ExitCode(2)
        }

        do {
            let (context, paths, db) = try CLIUtils.loadOrInitProject(projectDir: projectDir)
            let memory = try SQLiteMemoryStore(db: db, projectId: context.projectId, recordsDir: paths.recordsDir)
            guard let run = try memory.getRun(id: id) else {
                let error = CLIError(code: "RUN_NOT_FOUND", title: "Run was not found", message: "Run not found: \(id)", resolution: "Run `gda runs list --json` to find recent run IDs.", retryable: false, suggestedCommand: "gda runs list --project-dir \(projectDir) --json")
                if json { CLIResponse.failure(command: "runs.undo", error: error) } else { print(error.message) }
                throw ExitCode(1)
            }

            let evidenceIds = try memory.evidenceRecords(runId: id).map(\.id)
            let expired = try memory.expireAtoms(sourceEvidenceIds: evidenceIds)
            try memory.updateRunStatus(id: id, status: "undone", completedAt: run.completedAt, error: run.error)

            if json {
                CLIResponse.success(
                    command: "runs.undo",
                    data: ["run_id": id, "expired_atom_count": expired, "evidence_ids": evidenceIds]
                )
            } else {
                print("Expired \(expired) memory atoms from \(id).")
            }
        } catch let exit as ExitCode {
            throw exit
        } catch {
            if json { CLIResponse.failure(command: "runs.undo", error: error) } else { print("Error: \(error.localizedDescription)") }
            throw ExitCode(1)
        }
    }
}

struct RunsRecoverCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recover",
        abstract: "Recover memory writes from a saved analysis artifact"
    )

    @Option(name: .long, help: "Project directory path")
    var projectDir: String = ".gda"

    @Option(name: .long, help: "Run ID")
    var id: String

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }

        do {
            let (context, paths, db) = try CLIUtils.loadOrInitProject(projectDir: projectDir)
            let memory = try SQLiteMemoryStore(db: db, projectId: context.projectId, recordsDir: paths.recordsDir)
            guard let run = try memory.getRun(id: id) else {
                let error = CLIError(code: "RUN_NOT_FOUND", title: "Run was not found", message: "Run not found: \(id)", resolution: "Run `gda runs list --json` to find recent run IDs.", retryable: false, suggestedCommand: "gda runs list --project-dir \(projectDir) --json")
                if json { CLIResponse.failure(command: "runs.recover", error: error) } else { print(error.message) }
                throw ExitCode(1)
            }

            let analysisURL = paths.artifactDir(runId: id).appendingPathComponent("analysis.json")
            guard FileManager.default.fileExists(atPath: analysisURL.path) else {
                let error = CLIError(
                    code: "ANALYSIS_ARTIFACT_MISSING",
                    title: "Analysis artifact is missing",
                    message: "No saved analysis artifact exists for run \(id).",
                    resolution: "Recovery can replay memory only when `.gda/artifacts/<run-id>/analysis.json` exists.",
                    retryable: false
                )
                if json { CLIResponse.failure(command: "runs.recover", error: error) } else { print(error.message) }
                throw ExitCode(1)
            }

            var analysis = try JSON.decoder.decode(DesignAnalysis.self, from: Data(contentsOf: analysisURL))
            let evidenceIds = try memory.evidenceRecords(runId: id).map(\.id)
            let fallbackEvidenceId = evidenceIds.first ?? StableID.evidence()
            if evidenceIds.isEmpty {
                try memory.insertEvidenceRecord(
                    id: fallbackEvidenceId,
                    runId: id,
                    sessionId: run.sessionId,
                    screenName: run.screenName,
                    kind: "recoveredAnalysis",
                    contentPath: analysisURL.path,
                    summary: "Recovered from saved analysis artifact"
                )
            }

            analysis = DesignAnalysisPostProcessor.attachRunMetadata(
                analysis,
                runId: id,
                projectId: context.projectId,
                model: run.model,
                screenName: run.screenName,
                evidenceIds: [fallbackEvidenceId]
            )

            let written = try await MemoryWriter(store: memory).applyWrites(
                analysis.memoryWrites,
                sourceEvidenceIds: [fallbackEvidenceId],
                projectId: context.projectId,
                screenName: run.screenName
            )
            let compaction = try await MemoryCompactor(store: memory, projectId: context.projectId).updateSceneAndProfileFastPath(
                from: analysis,
                screenName: run.screenName ?? "",
                runId: id,
                evidenceId: fallbackEvidenceId
            )
            try memory.updateRunStatus(id: id, status: "recovered", completedAt: Date(), error: nil)

            if json {
                CLIResponse.success(
                    command: "runs.recover",
                    data: [
                        "run_id": id,
                        "written_atom_ids": written,
                        "scene_updated": compaction.sceneUpdated,
                        "profile_updated": compaction.profileUpdated
                    ]
                )
            } else {
                print("Recovered \(written.count) memory atoms from \(id).")
            }
        } catch let exit as ExitCode {
            throw exit
        } catch {
            if json { CLIResponse.failure(command: "runs.recover", error: error) } else { print("Error: \(error.localizedDescription)") }
            throw ExitCode(1)
        }
    }
}

struct RunsShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show a specific analyze run"
    )

    @Option(name: .long, help: "Project directory path")
    var projectDir: String = ".gda"

    @Option(name: .long, help: "Run ID")
    var id: String

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }

        do {
            let (context, paths, db) = try CLIUtils.loadOrInitProject(projectDir: projectDir)
            let memory = try SQLiteMemoryStore(db: db, projectId: context.projectId, recordsDir: paths.recordsDir)

            guard let run = try memory.getRun(id: id) else {
                let error = CLIError(
                    code: "RUN_NOT_FOUND",
                    title: "Run was not found",
                    message: "Run not found: \(id)",
                    resolution: "Run `gda runs list --json` to find recent run IDs.",
                    retryable: false,
                    suggestedCommand: "gda runs list --project-dir \(projectDir) --json",
                    exitCode: 1
                )
                if json { CLIResponse.failure(command: "runs.show", error: error) } else { print("Run not found: \(id)") }
                throw ExitCode(1)
            }

            let artifacts = artifactStatus(paths: paths, runId: id)

            if json {
                let runObject = try CLIResponse.object(from: run)
                CLIResponse.success(
                    command: "runs.show",
                    data: [
                        "run": runObject,
                        "artifacts": artifacts
                    ],
                    nextActions: nextActions(for: run, projectDir: projectDir)
                )
            } else {
                print("Run: \(run.id)")
                print("  Status: \(run.status)")
                print("  Screen: \(run.screenName ?? "unknown")")
                print("  Model: \(run.model)")
                print("  Started: \(run.startedAt)")
                if let completedAt = run.completedAt {
                    print("  Completed: \(completedAt)")
                }
                if let error = run.error {
                    print("  Error: \(error)")
                }
                print("  Artifacts: \(artifacts)")
            }
        } catch let exit as ExitCode {
            throw exit
        } catch {
            if json { CLIResponse.failure(command: "runs.show", error: error) } else { print("Error: \(error.localizedDescription)") }
            throw ExitCode(1)
        }
    }

    private func artifactStatus(paths: ArtifactPaths, runId: String) -> [String: Any] {
        let runDir = paths.artifactDir(runId: runId)
        let analysisPath = runDir.appendingPathComponent("analysis.json").path
        let promptPath = runDir.appendingPathComponent("prompt.txt").path
        return [
            "run_dir": runDir.path,
            "analysis_path": analysisPath,
            "analysis_exists": FileManager.default.fileExists(atPath: analysisPath),
            "prompt_path": promptPath,
            "prompt_exists": FileManager.default.fileExists(atPath: promptPath)
        ]
    }

    private func nextActions(for run: RunRecord, projectDir: String) -> [[String: Any]] {
        if run.status == "failed" {
            return [["label": "Check project health", "command": "gda doctor --project-dir \(projectDir) --image \(run.imagePath) --json"]]
        }
        if run.status != "completed" {
            return [["label": "Inspect project health", "command": "gda doctor --project-dir \(projectDir) --json"]]
        }
        return [["label": "Search memory", "command": "gda memory search --project-dir \(projectDir) --query \"\(run.screenName ?? run.id)\" --json"]]
    }
}
