import ArgumentParser
import Foundation
import GeminiDesignAgentCore

struct LockCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lock",
        abstract: "Inspect or recover project locks",
        subcommands: [LockStatusCommand.self, LockClearCommand.self]
    )
}

struct LockStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Inspect project and archive lock metadata")

    @Option(name: .long, help: "Project directory path")
    var projectDir: String = ".gda"

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }
        let reports = lockReports(projectDir: projectDir)
        if json {
            CLIResponse.success(command: "lock.status", data: ["project_dir": projectDir, "locks": reports])
        } else {
            for report in reports {
                print("\(report["kind"] as? String ?? "lock"): \(report["state"] as? String ?? "unknown")")
                print("  \(report["path"] as? String ?? "")")
            }
        }
    }
}

struct LockClearCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "clear", abstract: "Force-clear project and archive locks after confirming no process is active")

    @Option(name: .long, help: "Project directory path")
    var projectDir: String = ".gda"

    @Flag(name: .long, help: "Required acknowledgement that active locks may be removed")
    var force: Bool = false

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }
        guard force else {
            let error = CLIError(
                code: "LOCK_FORCE_REQUIRED",
                title: "Force acknowledgement is required",
                message: "`gda lock clear` requires `--force` because it can remove a lock held by another process.",
                resolution: "Run `gda lock status` first, confirm no gda process is active, then rerun with `--force`.",
                retryable: false,
                suggestedCommand: "gda lock status --project-dir \(projectDir)",
                exitCode: 2
            )
            if json { CLIResponse.failure(command: "lock.clear", error: error) } else { print("Error: \(error.message)") }
            throw ExitCode(error.exitCode)
        }

        var results: [[String: Any]] = []
        var failures: [Error] = []
        for target in lockTargets(projectDir: projectDir) {
            do {
                let result = try FileSystemLock.forceClear(target.url)
                results.append(["kind": target.kind, "path": target.url.path, "result": result.rawValue])
            } catch {
                failures.append(error)
                results.append(["kind": target.kind, "path": target.url.path, "result": "failed", "error": error.localizedDescription])
            }
        }

        if json {
            CLIResponse.envelope(
                ok: failures.isEmpty,
                command: "lock.clear",
                data: ["project_dir": projectDir, "locks": results],
                diagnostics: failures.map { ["name": "lock.clear", "status": "fail", "message": $0.localizedDescription] }
            )
        } else {
            for result in results {
                print("\(result["kind"] ?? "lock"): \(result["result"] ?? "unknown")")
            }
        }

        if !failures.isEmpty {
            throw ExitCode(10)
        }
    }
}

private func lockTargets(projectDir: String) -> [(kind: String, url: URL)] {
    let paths = ArtifactPaths(projectDir: URL(fileURLWithPath: projectDir, isDirectory: true))
    return [("project", paths.projectLockDir), ("records", paths.recordsLockDir)]
}

private func lockReports(projectDir: String) -> [[String: Any]] {
    lockTargets(projectDir: projectDir).map { target in
        let inspection = FileSystemLock.inspect(target.url)
        var report: [String: Any] = [
            "kind": target.kind,
            "path": target.url.path,
            "state": inspection.state.rawValue,
            "present": inspection.isPresent
        ]
        if let metadata = inspection.metadata {
            let lockID: Any = metadata.lockID.map { $0 as Any } ?? NSNull()
            report["metadata"] = [
                "lock_id": lockID,
                "pid": metadata.pid,
                "host": metadata.host,
                "acquired_at": ISO8601DateFormatter().string(from: metadata.acquiredAt),
                "age_seconds": max(0, Int(Date().timeIntervalSince(metadata.acquiredAt))),
                "purpose": metadata.purpose
            ]
        }
        if let detail = inspection.detail { report["detail"] = detail }
        return report
    }
}
