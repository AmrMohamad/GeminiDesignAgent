import Foundation
import ArgumentParser
import GeminiDesignAgentCore

struct SnapshotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot",
        abstract: "Create, list, show, or restore memory snapshots",
        subcommands: [
            SnapshotCreateCommand.self,
            SnapshotListCommand.self,
            SnapshotShowCommand.self,
            SnapshotRestoreCommand.self
        ]
    )
}

private struct SnapshotPayload: Codable {
    var id: String
    var name: String
    var createdAt: Date
    var profile: ProjectProfile?
    var atoms: [MemoryAtom]
}

struct SnapshotCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a memory snapshot")

    @Option(name: .long, help: "Project directory path")
    var projectDir: String = ".gda"

    @Option(name: .long, help: "Snapshot name")
    var name: String = "snapshot"

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }
        do {
            let (context, paths, db) = try CLIUtils.loadOrInitProject(projectDir: projectDir)
            let memory = try SQLiteMemoryStore(db: db, projectId: context.projectId, recordsDir: paths.recordsDir)
            let payload = SnapshotPayload(
                id: "snap_\(UUID().uuidString.lowercased())",
                name: name,
                createdAt: Date(),
                profile: try await memory.getProjectProfile(),
                atoms: try memory.activeAtoms()
            )
            let url = snapshotDir(paths).appendingPathComponent("\(payload.id).json")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSON.encoder.encode(payload).write(to: url)

            if json {
                CLIResponse.success(command: "snapshot.create", data: ["id": payload.id, "name": name, "path": url.path, "atom_count": payload.atoms.count])
            } else {
                print("Created snapshot \(payload.id): \(url.path)")
            }
        } catch {
            if json { CLIResponse.failure(command: "snapshot.create", error: error) } else { print("Error: \(error.localizedDescription)") }
            throw ExitCode(1)
        }
    }
}

struct SnapshotListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List memory snapshots")

    @Option(name: .long, help: "Project directory path")
    var projectDir: String = ".gda"

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }
        do {
            let (_, paths, _) = try CLIUtils.loadOrInitProject(projectDir: projectDir)
            let snapshots = try loadSnapshots(paths)
            if json {
                try CLIResponse.successEncodable(command: "snapshot.list", data: ["snapshots": snapshots])
            } else {
                for snapshot in snapshots {
                    print("\(snapshot.id) \(snapshot.name) atoms:\(snapshot.atoms.count)")
                }
            }
        } catch {
            if json { CLIResponse.failure(command: "snapshot.list", error: error) } else { print("Error: \(error.localizedDescription)") }
            throw ExitCode(1)
        }
    }
}

struct SnapshotShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Show a memory snapshot")

    @Option(name: .long, help: "Project directory path")
    var projectDir: String = ".gda"

    @Option(name: .long, help: "Snapshot ID")
    var id: String

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }
        do {
            let (_, paths, _) = try CLIUtils.loadOrInitProject(projectDir: projectDir)
            let snapshot = try loadSnapshot(paths, id: id)
            if json {
                try CLIResponse.successEncodable(command: "snapshot.show", data: snapshot)
            } else {
                print("\(snapshot.id) \(snapshot.name) atoms:\(snapshot.atoms.count)")
            }
        } catch {
            if json { CLIResponse.failure(command: "snapshot.show", error: error) } else { print("Error: \(error.localizedDescription)") }
            throw ExitCode(1)
        }
    }
}

struct SnapshotRestoreCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "restore", abstract: "Restore atoms/profile from a snapshot")

    @Option(name: .long, help: "Project directory path")
    var projectDir: String = ".gda"

    @Option(name: .long, help: "Snapshot ID")
    var id: String

    @Flag(name: .long, help: "Confirm restore")
    var confirm: Bool = false

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }

        guard confirm else {
            let error = CLIError(code: "CONFIRMATION_REQUIRED", title: "Restore requires confirmation", message: "`gda snapshot restore` writes snapshot memory into the current project.", resolution: "Rerun with `--confirm` if this is intentional.", retryable: false, suggestedCommand: "gda snapshot restore --project-dir \(projectDir) --id \(id) --confirm --json", exitCode: 2)
            if json { CLIResponse.failure(command: "snapshot.restore", error: error) } else { print(error.message) }
            throw ExitCode(2)
        }

        do {
            let (context, paths, db) = try CLIUtils.loadOrInitProject(projectDir: projectDir)
            let snapshot = try loadSnapshot(paths, id: id)
            let memory = try SQLiteMemoryStore(db: db, projectId: context.projectId, recordsDir: paths.recordsDir)
            if let profile = snapshot.profile {
                var restored = profile
                restored.projectId = context.projectId
                try await memory.upsertProjectProfile(restored)
            }
            var restoredAtomCount = 0
            for atom in snapshot.atoms {
                var restored = atom
                restored.projectId = context.projectId
                _ = try await memory.upsertAtom(restored)
                restoredAtomCount += 1
            }

            if json {
                CLIResponse.success(command: "snapshot.restore", data: ["id": id, "restored_atom_count": restoredAtomCount, "profile_restored": snapshot.profile != nil])
            } else {
                print("Restored \(restoredAtomCount) atoms from \(id).")
            }
        } catch let exit as ExitCode {
            throw exit
        } catch {
            if json { CLIResponse.failure(command: "snapshot.restore", error: error) } else { print("Error: \(error.localizedDescription)") }
            throw ExitCode(1)
        }
    }
}

private func snapshotDir(_ paths: ArtifactPaths) -> URL {
    paths.rootDir.appendingPathComponent("snapshots")
}

private func loadSnapshots(_ paths: ArtifactPaths) throws -> [SnapshotPayload] {
    let dir = snapshotDir(paths)
    guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
        return []
    }
    return try files
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .map { try JSON.decoder.decode(SnapshotPayload.self, from: Data(contentsOf: $0)) }
}

private func loadSnapshot(_ paths: ArtifactPaths, id: String) throws -> SnapshotPayload {
    let url = snapshotDir(paths).appendingPathComponent("\(id).json")
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw CLIError(code: "SNAPSHOT_NOT_FOUND", title: "Snapshot was not found", message: "Snapshot not found: \(id)", resolution: "Run `gda snapshot list --json` to find available snapshots.", retryable: false, suggestedCommand: "gda snapshot list --project-dir \(paths.rootDir.path) --json")
    }
    return try JSON.decoder.decode(SnapshotPayload.self, from: Data(contentsOf: url))
}
