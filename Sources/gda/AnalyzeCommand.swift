import Foundation
import ArgumentParser
import GeminiDesignAgentCore

struct AnalyzeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "analyze",
        abstract: "Analyze a UI screenshot with Gemini vision",
        discussion: """
        Examples:
          gda analyze --image home.png --screen Home --json
          gda analyze --project-dir .gda --image settings.png --screen Settings --debug-prompt --json
          gda doctor --project-dir .gda --image home.png --json
        """
    )

    @Option(name: .long, help: "Project directory path")
    var projectDir: String = ".gda"

    @Option(name: .long, help: "Path to screenshot image")
    var image: String?

    @Option(name: .long, help: "Screen or component name")
    var screen: String?

    @Option(name: .long, help: "Analysis request/instructions")
    var request: String = "Extract layout, spacing, typography, colors, reusable components, and development-ready implementation values."

    @Option(name: .long, help: "Preset: layout, tokens, components, accessibility, implementation")
    var preset: String?

    @Option(name: .long, help: "Batch file with one image path per line, optionally followed by comma/tab screen name")
    var batchFile: String?

    @Option(name: .long, help: "Gemini model to use")
    var model: String = GDAContract.defaultModel

    @Option(name: .long, help: "Max memory atoms to inject")
    var memoryLimit: Int = 8

    @Option(name: .long, help: "Device pixel ratio for logical bboxCss output")
    var devicePixelRatio: Double = 1.0

    @Option(name: .long, help: "Viewport label, for example 375x812 or desktop")
    var viewport: String?

    @Option(name: .long, help: "Theme label, for example light or dark")
    var theme: String?

    @Option(name: .long, help: "UI state label, for example default, hover, disabled")
    var state: String?

    @Option(name: .long, help: "Locale direction, for example ltr or rtl")
    var localeDirection: String?

    @Option(name: .long, help: "Request timeout in seconds")
    var timeoutSeconds: Int = 120

    @Option(name: .long, help: "Seconds to wait for the project lock")
    var lockTimeout: Int = 30

    @Option(name: .long, help: "Temporary Gemini API key override for this run")
    var apiKey: String?

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    @Flag(name: .long, help: "Write prompt to artifacts for debugging")
    var debugPrompt: Bool = false

    @Flag(name: .long, help: "Disable writing raw artifacts to disk")
    var noStore: Bool = false

    @Flag(name: .long, help: "Fail immediately when another gda process holds the project lock")
    var failIfLocked: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }

        if let batchFile {
            try await runBatch(batchFile: batchFile)
            return
        }

        guard let image, let screen else {
            let error = CLIError(
                code: "ANALYZE_INPUT_REQUIRED",
                title: "Analyze input is incomplete",
                message: "`gda analyze` requires `--image` and `--screen`, or `--batch-file`.",
                resolution: "Pass `--image <path> --screen <name>` or use `--batch-file`.",
                retryable: false,
                exitCode: 2
            )
            if json { CLIResponse.failure(command: "analyze", error: error) } else { print("Error: \(error.message)") }
            throw ExitCode(2)
        }

        let imageURL = URL(fileURLWithPath: image)

        guard FileManager.default.fileExists(atPath: imageURL.path) else {
            let error = CLIError(
                code: "IMAGE_NOT_FOUND",
                title: "Image file was not found",
                message: "Image file not found: \(image)",
                resolution: "Pass an existing PNG or JPEG path with `--image`.",
                retryable: false,
                exitCode: 2
            )
            if json { CLIResponse.failure(command: "analyze", error: error) } else { print("Error: \(error.message)") }
            throw ExitCode(2)
        }

        do {
            let (context, paths, db) = try CLIUtils.loadOrInitProject(projectDir: projectDir)
            let projectLock = try await ProjectLock.acquire(
                projectDir: paths.rootDir,
                timeoutSeconds: lockTimeout,
                failIfLocked: failIfLocked
            )
            defer { projectLock.release() }

            let memory = try SQLiteMemoryStore(db: db, projectId: context.projectId, recordsDir: paths.recordsDir)
            let gemini = try CLIUtils.loadAPIClient(apiKey: apiKey, timeoutSeconds: timeoutSeconds)

            let session = GeminiDesignSession(
                context: context,
                gemini: gemini,
                memory: memory,
                paths: paths
            )

            let input = AnalyzeScreenInput(
                imageURL: imageURL,
                screenName: screen,
                request: effectiveRequest,
                model: model,
                memoryLimit: memoryLimit,
                debugPrompt: debugPrompt,
                storeArtifacts: !noStore,
                devicePixelRatio: max(0.01, devicePixelRatio),
                viewport: viewport,
                theme: theme,
                state: state,
                localeDirection: localeDirection
            )

            let result = try await session.analyzeScreen(input)

            if json {
                try CLIResponse.successEncodable(
                    command: "analyze",
                    data: result,
                    diagnostics: try diagnosticObjects(for: result),
                    nextActions: [
                        ["label": "Search memory", "command": "gda memory search --project-dir \(projectDir) --query \"\(screen)\" --json"],
                        ["label": "Check project health", "command": "gda doctor --project-dir \(projectDir) --json"]
                    ]
                )
            } else {
                print("Analysis complete: \(screen)")
                print("  Summary: \(result.analysis.summary.prefix(200))")
                print("  Elements found: \(result.analysis.elements.count)")
                print("  Components: \(result.analysis.components.count)")
                print("  Memory atoms written: \(result.memory.writtenAtomIds.count)")
            }
        } catch {
            if json { CLIResponse.failure(command: "analyze", error: error) } else { print("Error: \(errorMessage(for: error))") }
            throw ExitCode(mapExitCode(for: error))
        }
    }

    private var effectiveRequest: String {
        guard let preset, let presetText = presetPrompt(preset) else {
            return request
        }
        return "\(presetText)\n\nUser request: \(request)"
    }

    private func runBatch(batchFile: String) async throws {
        let items = try parseBatchFile(batchFile)
        guard !items.isEmpty else {
            let error = CLIError(code: "EMPTY_BATCH", title: "Batch file is empty", message: "No image paths were found in \(batchFile).", resolution: "Add one image path per line, optionally followed by a comma or tab screen name.", retryable: false, exitCode: 2)
            if json { CLIResponse.failure(command: "analyze.batch", error: error) } else { print("Error: \(error.message)") }
            throw ExitCode(2)
        }

        do {
            let (context, paths, db) = try CLIUtils.loadOrInitProject(projectDir: projectDir)
            let projectLock = try await ProjectLock.acquire(projectDir: paths.rootDir, timeoutSeconds: lockTimeout, failIfLocked: failIfLocked)
            defer { projectLock.release() }

            let memory = try SQLiteMemoryStore(db: db, projectId: context.projectId, recordsDir: paths.recordsDir)
            let gemini = try CLIUtils.loadAPIClient(apiKey: apiKey, timeoutSeconds: timeoutSeconds)
            let session = GeminiDesignSession(context: context, gemini: gemini, memory: memory, paths: paths)

            var outputs: [[String: Any]] = []
            var diagnostics: [[String: Any]] = []
            var failed = false

            for item in items {
                do {
                    guard FileManager.default.fileExists(atPath: item.imageURL.path) else {
                        throw CLIError(code: "IMAGE_NOT_FOUND", title: "Image file was not found", message: "Image file not found: \(item.imageURL.path)", resolution: "Fix the batch file path and retry.", retryable: false, exitCode: 2)
                    }

                    let result = try await session.analyzeScreen(AnalyzeScreenInput(
                        imageURL: item.imageURL,
                        screenName: item.screenName,
                        request: effectiveRequest,
                        model: model,
                        memoryLimit: memoryLimit,
                        debugPrompt: debugPrompt,
                        storeArtifacts: !noStore,
                        devicePixelRatio: max(0.01, devicePixelRatio),
                        viewport: viewport,
                        theme: theme,
                        state: state,
                        localeDirection: localeDirection
                    ))
                    outputs.append(["ok": true, "screen": item.screenName, "result": try CLIResponse.object(from: result)])
                    diagnostics.append(contentsOf: try diagnosticObjects(for: result).map { diagnostic in
                        var attributed = diagnostic
                        attributed["run_id"] = result.runId
                        attributed["screen"] = item.screenName
                        return attributed
                    })
                } catch {
                    failed = true
                    outputs.append([
                        "ok": false,
                        "screen": item.screenName,
                        "image": item.imageURL.path,
                        "error": itemErrorObject(error)
                    ])
                }
            }

            if json {
                CLIResponse.envelope(
                    ok: !failed,
                    command: "analyze.batch",
                    data: ["results": outputs, "count": outputs.count, "failed_count": outputs.filter { ($0["ok"] as? Bool) == false }.count],
                    diagnostics: diagnostics,
                    nextActions: [["label": "Inspect runs", "command": "gda runs list --project-dir \(projectDir) --json"]]
                )
            } else {
                for output in outputs {
                    print("\(output["screen"] ?? "unknown"): \((output["ok"] as? Bool) == true ? "ok" : "failed")")
                }
            }

            if failed {
                throw ExitCode(1)
            }
        } catch let exit as ExitCode {
            throw exit
        } catch {
            if json { CLIResponse.failure(command: "analyze.batch", error: error) } else { print("Error: \(errorMessage(for: error))") }
            throw ExitCode(mapExitCode(for: error))
        }
    }

    private func diagnosticObjects(for result: AnalyzeResult) throws -> [[String: Any]] {
        guard let metrics = result.metrics else { return [] }
        return try metrics.nonFatalDiagnostics.compactMap { diagnostic in
            try CLIResponse.object(from: diagnostic) as? [String: Any]
        }
    }

    private struct BatchItem {
        var imageURL: URL
        var screenName: String
    }

    private func parseBatchFile(_ path: String) throws -> [BatchItem] {
        let content = try String(contentsOfFile: path, encoding: .utf8)
        return content
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { line in
                let parts = line.split(whereSeparator: { $0 == "," || $0 == "\t" }).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                let imagePath = parts[0]
                let imageURL = URL(fileURLWithPath: imagePath)
                let screenName = parts.count > 1 && !parts[1].isEmpty
                    ? parts[1]
                    : imageURL.deletingPathExtension().lastPathComponent
                return BatchItem(imageURL: imageURL, screenName: screenName)
            }
    }

    private func itemErrorObject(_ error: Error) -> [String: Any] {
        var object: [String: Any] = [
            "message": errorMessage(for: error),
            "retryable": false
        ]
        if let failure = error as? AnalyzeRunFailure {
            object["run_id"] = failure.runId
            object["phase"] = failure.phase
        }
        return object
    }

    private func presetPrompt(_ preset: String) -> String? {
        switch preset {
        case "layout":
            return "Focus on layout hierarchy, alignment, grid, spacing, and responsive structure."
        case "tokens":
            return "Focus on design tokens: colors, typography, spacing, radii, shadows, and reusable values."
        case "components":
            return "Focus on reusable components, variants, states, and implementation-ready component boundaries."
        case "accessibility":
            return "Focus on accessibility risks, contrast, touch targets, reading order, labels, and dynamic type concerns."
        case "implementation":
            return "Focus on code-ready implementation guidance, CSS/SwiftUI/UIKit layout values, and reusable abstractions."
        default:
            return nil
        }
    }

    private func errorMessage(for error: Error) -> String {
        if let failure = error as? AnalyzeRunFailure {
            return errorMessage(for: failure.underlying)
        }
        if case GeminiError.apiKeyMissing = error {
            return "Gemini API key is not configured. Run `gda auth onboard` or set GEMINI_API_KEY for a temporary CI/debugging override."
        }
        return error.localizedDescription
    }

    private func mapExitCode(for error: Error) -> Int32 {
        if let failure = error as? AnalyzeRunFailure {
            return mapExitCode(for: failure.underlying)
        }
        switch error {
        case let gErr as GeminiError:
            switch gErr {
            case .apiKeyMissing: return 6
            case .rateLimited: return 8
            case .timeout: return 7
            case .networkUnavailable, .dnsFailure, .connectionFailed: return 7
            case .invalidJSON: return 4
            case .imageTooLarge: return 2
            case .contentBlocked, .noCandidates, .interactionIncomplete, .interactionFailed, .interactionCancelled, .invalidSynchronousInteractionState, .unsupportedInteractionState: return 4
            case .quotaExhausted: return 8
            case .billingDisabled, .invalidAPIKey: return 6
            case .modelNotFound: return 9
            default: return 9
            }
        default: return 9
        }
    }
}
