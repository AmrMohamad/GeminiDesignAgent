import Foundation
import ArgumentParser
import GeminiDesignAgentCore

struct GCCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gc",
        abstract: "Inspect and clean old local artifacts",
        discussion: """
        Examples:
          gda gc --project-dir .gda --json
          gda gc --project-dir .gda --max-raw-refs-age-days 30 --apply --json
        """
    )

    @Option(name: .long, help: "Project directory path")
    var projectDir: String = ".gda"

    @Option(name: .long, help: "Delete raw refs older than this many days")
    var maxRawRefsAgeDays: Int = 90

    @Option(name: .long, help: "Expire low-confidence atoms older than this many days")
    var expireLowConfidenceOlderThanDays: Int?

    @Option(name: .long, help: "Low-confidence atom threshold")
    var minConfidence: Double = 0.55

    @Flag(name: .long, help: "Apply cleanup. Without this, gc is dry-run only")
    var apply: Bool = false

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }

        do {
            let (_, paths, db) = try CLIUtils.loadOrInitProject(projectDir: projectDir)
            let configData = try Data(contentsOf: paths.configPath)
            let configJSON = try JSONSerialization.jsonObject(with: configData) as? [String: Any]
            let projectId = configJSON?["project_id"] as? String ?? ""
            let memory = try SQLiteMemoryStore(db: db, projectId: projectId, recordsDir: paths.recordsDir)
            let plan = try collectPlan(paths: paths)
            let atomCandidates = try pruneAtomCandidates(memory: memory)

            if apply {
                for file in plan.prunableRefs {
                    try? FileManager.default.removeItem(at: file)
                }
                _ = try memory.expireAtoms(ids: atomCandidates.map(\.id))
                try db.exec("ANALYZE")
                try db.exec("VACUUM")
            }

            let data: [String: Any] = [
                "dry_run": !apply,
                "project_dir": projectDir,
                "max_raw_refs_age_days": maxRawRefsAgeDays,
                "raw_refs": [
                    "count": plan.refCount,
                    "bytes": plan.refBytes,
                    "prunable_count": plan.prunableRefs.count,
                    "prunable_bytes": plan.prunableBytes
                ],
                "records": [
                    "bytes": directorySize(paths.recordsDir)
                ],
                "memory_prune": [
                    "candidate_count": atomCandidates.count,
                    "expired_count": apply ? atomCandidates.count : 0,
                    "min_confidence": minConfidence,
                    "older_than_days": expireLowConfidenceOlderThanDays.map { $0 as Any } ?? NSNull()
                ],
                "database": [
                    "bytes": fileSize(paths.dbPath),
                    "maintenance": apply ? "ANALYZE and VACUUM completed" : "not applied"
                ]
            ]

            if json {
                CLIResponse.success(
                    command: "gc",
                    data: data,
                    nextActions: apply ? [] : [["label": "Apply cleanup", "command": "gda gc --project-dir \(projectDir) --max-raw-refs-age-days \(maxRawRefsAgeDays) --apply --json"]]
                )
            } else {
                print(apply ? "Garbage collection complete." : "Garbage collection dry run.")
                print("  Raw refs: \(plan.refCount), prunable: \(plan.prunableRefs.count)")
                print("  Prunable bytes: \(plan.prunableBytes)")
            }
        } catch {
            if json { CLIResponse.failure(command: "gc", error: error) } else { print("Error: \(error.localizedDescription)") }
            throw ExitCode(1)
        }
    }

    private struct GCPlan {
        var refCount: Int
        var refBytes: Int
        var prunableRefs: [URL]
        var prunableBytes: Int
    }

    private func collectPlan(paths: ArtifactPaths) throws -> GCPlan {
        let cutoff = Date().addingTimeInterval(-Double(maxRawRefsAgeDays) * 24 * 60 * 60)
        var refCount = 0
        var refBytes = 0
        var prunableRefs: [URL] = []
        var prunableBytes = 0

        guard let enumerator = FileManager.default.enumerator(at: paths.refsDir, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]) else {
            return GCPlan(refCount: 0, refBytes: 0, prunableRefs: [], prunableBytes: 0)
        }

        for case let url as URL in enumerator where url.pathExtension == "json" {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0
            refCount += 1
            refBytes += size
            if let modified = values.contentModificationDate, modified < cutoff {
                prunableRefs.append(url)
                prunableBytes += size
            }
        }

        return GCPlan(refCount: refCount, refBytes: refBytes, prunableRefs: prunableRefs, prunableBytes: prunableBytes)
    }

    private func pruneAtomCandidates(memory: SQLiteMemoryStore) throws -> [MemoryAtom] {
        guard let days = expireLowConfidenceOlderThanDays else { return [] }
        let cutoff = Date().addingTimeInterval(-Double(max(0, days)) * 24 * 60 * 60)
        return try memory.lowConfidencePruneCandidates(olderThan: cutoff, confidenceBelow: minConfidence)
    }

    private func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    private func directorySize(_ url: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }

        var total = 0
        for case let fileURL as URL in enumerator {
            total += (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }
}
