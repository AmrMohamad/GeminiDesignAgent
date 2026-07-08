import Foundation
import ArgumentParser
import GeminiDesignAgentCore

struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Validate auth, project storage, database health, and optional image input",
        discussion: """
        Examples:
          gda doctor --project-dir .gda
          gda doctor --project-dir .gda --image home.png --json
          gda doctor --project-dir .gda --model gemini-2.5-flash --json
        """
    )

    @Option(name: .long, help: "Project directory path")
    var projectDir: String = ".gda"

    @Option(name: .long, help: "Optional screenshot image to validate")
    var image: String?

    @Option(name: .long, help: "Gemini model name to validate")
    var model: String = "gemini-2.5-flash"

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }

        let result = await Doctor(projectDir: projectDir, image: image, model: model).run()

        if json {
            CLIResponse.envelope(
                ok: result.ready,
                command: "doctor",
                data: result.data,
                diagnostics: result.diagnostics,
                nextActions: result.nextActions
            )
        } else {
            print(result.ready ? "gda doctor: ready" : "gda doctor: not ready")
            for check in result.checks {
                print("  [\(check.status)] \(check.name): \(check.message)")
                if let resolution = check.resolution {
                    print("      \(resolution)")
                }
            }
        }

        if !result.ready {
            throw ExitCode(1)
        }
    }
}

private struct Doctor {
    let projectDir: String
    let image: String?
    let model: String

    func run() async -> DoctorResult {
        var checks: [DoctorCheck] = []
        var stats: [String: Any] = [:]

        checks.append(checkModel(model))
        checks.append(checkAuth())

        let projectURL = URL(fileURLWithPath: projectDir, isDirectory: true)
        let paths = ArtifactPaths(projectDir: projectURL)
        checks.append(contentsOf: checkProject(paths: paths))

        if FileManager.default.fileExists(atPath: paths.configPath.path) {
            do {
                let db = try SQLiteDB(path: paths.dbPath.path)
                try DatabaseMigrator.migrate(db: db)
                let integrity = try db.integrityCheck()
                checks.append(DoctorCheck(
                    name: "database.integrity",
                    status: integrity == "ok" ? .pass : .fail,
                    message: integrity == "ok" ? "SQLite integrity check passed" : "SQLite integrity check returned: \(integrity)",
                    resolution: integrity == "ok" ? nil : "Back up `.gda`, then consider `gda reset` if the database cannot be repaired."
                ))

                if let context = try loadContext(paths: paths) {
                    let memory = try SQLiteMemoryStore(db: db, projectId: context.projectId, recordsDir: paths.recordsDir)
                    let memoryStats = try await memory.stats()
                    stats["project_id"] = context.projectId
                    stats["project_name"] = context.projectName
                    stats["atom_count"] = memoryStats.atomCount
                    stats["scene_count"] = memoryStats.sceneCount
                    stats["has_project_profile"] = memoryStats.hasProjectProfile
                    stats["db_bytes"] = fileSize(paths.dbPath)
                    stats["refs_bytes"] = directorySize(paths.refsDir)
                    stats["records_bytes"] = directorySize(paths.recordsDir)
                    checks.append(DoctorCheck(name: "memory.stats", status: .pass, message: "Memory store is readable", resolution: nil))
                }
            } catch {
                let mapped = mapStorageError(error)
                checks.append(mapped)
            }
        }

        if let image {
            checks.append(contentsOf: checkImage(image))
        }

        let ready = !checks.contains { $0.status == .fail }
        let data: [String: Any] = [
            "ready": ready,
            "project_dir": projectDir,
            "model": model,
            "checks": checks.map(\.object),
            "storage": stats
        ]

        return DoctorResult(
            ready: ready,
            data: data,
            checks: checks,
            diagnostics: checks.filter { $0.status != .pass }.map(\.diagnostic),
            nextActions: nextActions(for: checks)
        )
    }

    private func checkAuth() -> DoctorCheck {
        if let env = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return DoctorCheck(
                name: "auth",
                status: .warn,
                message: "GEMINI_API_KEY is set as a temporary override",
                resolution: "Prefer `gda auth onboard` for persistent local Keychain setup."
            )
        }

        do {
            let configured = try KeychainAPIKeyStore().load() != nil
            return DoctorCheck(
                name: "auth",
                status: configured ? .pass : .fail,
                message: configured ? "Gemini API key is configured in Keychain" : "Gemini API key is not configured",
                resolution: configured ? nil : "Run `gda auth onboard`."
            )
        } catch {
            return DoctorCheck(
                name: "auth",
                status: .fail,
                message: error.localizedDescription,
                resolution: "Repair Keychain access, or use GEMINI_API_KEY as a temporary CI/debugging override."
            )
        }
    }

    private func checkModel(_ model: String) -> DoctorCheck {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return DoctorCheck(name: "model", status: .fail, message: "Model name is empty", resolution: "Use a Gemini model such as `gemini-2.5-flash`.")
        }
        if trimmed.hasPrefix("models/") {
            return DoctorCheck(name: "model", status: .fail, message: "Model should not include the `models/` prefix", resolution: "Use `--model \(trimmed.replacingOccurrences(of: "models/", with: ""))`.")
        }
        if !trimmed.hasPrefix("gemini-") {
            return DoctorCheck(name: "model", status: .warn, message: "Model name does not look like a Gemini model", resolution: "Verify the model is supported by the Gemini API.")
        }
        return DoctorCheck(name: "model", status: .pass, message: "Model name shape is valid", resolution: nil)
    }

    private func checkProject(paths: ArtifactPaths) -> [DoctorCheck] {
        var checks: [DoctorCheck] = []
        let fm = FileManager.default

        if !fm.fileExists(atPath: paths.rootDir.path) {
            let parent = paths.rootDir.deletingLastPathComponent()
            let writableParent = fm.isWritableFile(atPath: parent.path)
            checks.append(DoctorCheck(
                name: "project.exists",
                status: .fail,
                message: "Project directory does not exist: \(paths.rootDir.path)",
                resolution: writableParent ? "Run `gda init --project-dir \(projectDir)`." : "Choose a writable parent directory, then run `gda init`."
            ))
            return checks
        }

        checks.append(DoctorCheck(name: "project.exists", status: .pass, message: "Project directory exists", resolution: nil))

        if !fm.fileExists(atPath: paths.configPath.path) {
            checks.append(DoctorCheck(name: "project.config", status: .fail, message: "Missing config.json in project directory", resolution: "Run `gda init --project-dir \(projectDir)` or pass the correct `--project-dir`."))
        } else {
            checks.append(DoctorCheck(name: "project.config", status: .pass, message: "Project config exists", resolution: nil))
        }

        for dir in [paths.rootDir, paths.recordsDir, paths.refsDir, paths.artifactsDir] {
            if fm.fileExists(atPath: dir.path) {
                let displayName = dir == paths.rootDir ? "project" : dir.lastPathComponent
                checks.append(DoctorCheck(
                    name: "writable.\(displayName)",
                    status: fm.isWritableFile(atPath: dir.path) ? .pass : .fail,
                    message: fm.isWritableFile(atPath: dir.path) ? "\(displayName) is writable" : "\(displayName) is not writable",
                    resolution: fm.isWritableFile(atPath: dir.path) ? nil : "Fix permissions or choose another `--project-dir`."
                ))
            }
        }

        return checks
    }

    private func checkImage(_ image: String) -> [DoctorCheck] {
        let url = URL(fileURLWithPath: image)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return [DoctorCheck(name: "image.exists", status: .fail, message: "Image file does not exist: \(image)", resolution: "Pass an existing PNG or JPEG screenshot.")]
        }

        do {
            let info = try ImageInfoReader.read(url)
            var checks: [DoctorCheck] = [
                DoctorCheck(name: "image.exists", status: .pass, message: "Image file exists", resolution: nil),
                DoctorCheck(name: "image.format", status: MimeTypeDetector.isSupportedImage(info.mimeType) ? .pass : .fail, message: "Image MIME type is \(info.mimeType)", resolution: MimeTypeDetector.isSupportedImage(info.mimeType) ? nil : "Convert the image to PNG or JPEG."),
                DoctorCheck(name: "image.size", status: info.fileSize <= 20 * 1024 * 1024 ? .pass : .fail, message: "Image size is \(info.fileSize) bytes", resolution: info.fileSize <= 20 * 1024 * 1024 ? nil : "Crop or compress the screenshot below 20MB for inline Gemini upload.")
            ]

            let megapixels = Double(info.width * info.height) / 1_000_000
            if info.height > 8_000 || megapixels > 40 {
                checks.append(DoctorCheck(name: "image.dimensions", status: .warn, message: "Image dimensions are \(info.width)x\(info.height)", resolution: "Very large or tall screenshots may be downscaled by the model; consider cropping to the relevant viewport."))
            } else {
                checks.append(DoctorCheck(name: "image.dimensions", status: .pass, message: "Image dimensions are \(info.width)x\(info.height)", resolution: nil))
            }

            return checks
        } catch {
            return [DoctorCheck(name: "image.read", status: .fail, message: error.localizedDescription, resolution: "Use a valid PNG or JPEG screenshot.")]
        }
    }

    private func loadContext(paths: ArtifactPaths) throws -> RuntimeContext? {
        let configData = try Data(contentsOf: paths.configPath)
        guard let configJSON = try JSONSerialization.jsonObject(with: configData) as? [String: Any],
              let projectId = configJSON["project_id"] as? String else {
            return nil
        }
        return RuntimeContext(
            projectId: projectId,
            projectName: configJSON["project_name"] as? String ?? "Design Project",
            projectDir: projectDir
        )
    }

    private func mapStorageError(_ error: Error) -> DoctorCheck {
        let message = error.localizedDescription
        let lower = "\(error) \(message)".lowercased()
        if lower.contains("malformed") || lower.contains("corrupt") {
            return DoctorCheck(name: "database.open", status: .fail, message: message, resolution: "The database may be corrupt. Back up `.gda`, then consider `gda reset`.")
        }
        if lower.contains("readonly") || lower.contains("disk") || lower.contains("full") {
            return DoctorCheck(name: "database.open", status: .fail, message: message, resolution: "Free disk space or choose a writable `--project-dir`.")
        }
        if lower.contains("locked") || lower.contains("busy") {
            return DoctorCheck(name: "database.open", status: .fail, message: message, resolution: "Wait for the other `gda` process to finish and retry.")
        }
        return DoctorCheck(name: "database.open", status: .fail, message: message, resolution: "Inspect the project directory and retry.")
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

    private func nextActions(for checks: [DoctorCheck]) -> [[String: Any]] {
        var actions: [[String: Any]] = []
        if checks.contains(where: { $0.name == "auth" && $0.status == .fail }) {
            actions.append(["label": "Start auth onboarding", "command": "gda auth onboard"])
        }
        if checks.contains(where: { ($0.name == "project.exists" || $0.name == "project.config") && $0.status == .fail }) {
            actions.append(["label": "Initialize project", "command": "gda init --project-dir \(projectDir) --json"])
        }
        if checks.contains(where: { $0.name.hasPrefix("image.") && $0.status == .fail }) {
            actions.append(["label": "Validate another image", "command": "gda doctor --project-dir \(projectDir) --image <path> --json"])
        }
        return actions
    }
}

private struct DoctorResult {
    let ready: Bool
    let data: [String: Any]
    let checks: [DoctorCheck]
    let diagnostics: [[String: Any]]
    let nextActions: [[String: Any]]
}

private struct DoctorCheck {
    enum Status: String {
        case pass
        case warn
        case fail
    }

    let name: String
    let status: Status
    let message: String
    let resolution: String?

    var object: [String: Any] {
        var value: [String: Any] = [
            "name": name,
            "status": status.rawValue,
            "message": message
        ]
        if let resolution {
            value["resolution"] = resolution
        }
        return value
    }

    var diagnostic: [String: Any] {
        object
    }
}
