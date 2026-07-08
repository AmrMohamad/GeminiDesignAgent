import Foundation
import ArgumentParser
import GeminiDesignAgentCore

struct AnalyzeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "analyze",
        abstract: "Analyze a UI screenshot with Gemini vision"
    )

    @Option(name: .long, help: "Project directory path")
    var projectDir: String = ".gda"

    @Option(name: .long, help: "Path to screenshot image")
    var image: String

    @Option(name: .long, help: "Screen or component name")
    var screen: String

    @Option(name: .long, help: "Analysis request/instructions")
    var request: String = "Extract layout, spacing, typography, colors, reusable components, and development-ready implementation values."

    @Option(name: .long, help: "Gemini model to use")
    var model: String = "gemini-2.5-flash"

    @Option(name: .long, help: "Max memory atoms to inject")
    var memoryLimit: Int = 8

    @Option(name: .long, help: "Request timeout in seconds")
    var timeoutSeconds: Int = 120

    @Option(name: .long, help: "Temporary Gemini API key override for this run")
    var apiKey: String?

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    @Flag(name: .long, help: "Write prompt to artifacts for debugging")
    var debugPrompt: Bool = false

    @Flag(name: .long, help: "Disable writing raw artifacts to disk")
    var noStore: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }

        let imageURL = URL(fileURLWithPath: image)

        guard FileManager.default.fileExists(atPath: imageURL.path) else {
            let error: [String: Any] = [
                "ok": false,
                "error": [
                    "code": "IMAGE_NOT_FOUND",
                    "message": "Image file not found: \(image)"
                ]
            ]
            if json { CLIUtils.printJSON(error) } else { print("Error: Image not found: \(image)") }
            throw ExitCode(2)
        }

        let (context, paths, db) = try CLIUtils.loadOrInitProject(projectDir: projectDir)
        let memory = try SQLiteMemoryStore(db: db, projectId: context.projectId, recordsDir: paths.recordsDir)

        do {
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
                request: request,
                model: model,
                memoryLimit: memoryLimit,
                debugPrompt: debugPrompt,
                storeArtifacts: !noStore
            )

            let result = try await session.analyzeScreen(input)

            if json {
                let data = try JSON.encoder.encode(result)
                if let str = String(data: data, encoding: .utf8) {
                    print(str)
                }
            } else {
                print("Analysis complete: \(screen)")
                print("  Summary: \(result.analysis.summary.prefix(200))")
                print("  Elements found: \(result.analysis.elements.count)")
                print("  Components: \(result.analysis.components.count)")
                print("  Memory atoms written: \(result.memory.writtenAtomIds.count)")
            }
        } catch {
            let errorOutput: [String: Any] = [
                "ok": false,
                "error": [
                    "code": errorCode(for: error),
                    "message": errorMessage(for: error)
                ]
            ]
            if json { CLIUtils.printJSON(errorOutput) } else { print("Error: \(errorMessage(for: error))") }
            throw ExitCode(mapExitCode(for: error))
        }
    }

    private func errorCode(for error: Error) -> String {
        switch error {
        case is GeminiError:
            switch error as! GeminiError {
            case .apiKeyMissing: return "API_KEY_MISSING"
            case .rateLimited: return "RATE_LIMITED"
            case .timeout: return "TIMEOUT"
            case .invalidJSON: return "INVALID_GEMINI_JSON"
            case .imageTooLarge: return "IMAGE_TOO_LARGE"
            default: return "GEMINI_ERROR"
            }
        case is ImageInfoReader.ImageError:
            return "IMAGE_READ_ERROR"
        default:
            return "INTERNAL_ERROR"
        }
    }

    private func errorMessage(for error: Error) -> String {
        if case GeminiError.apiKeyMissing = error {
            return "Gemini API key is not configured. Run `gda auth set` or set GEMINI_API_KEY for a temporary CI/debugging override."
        }
        return error.localizedDescription
    }

    private func mapExitCode(for error: Error) -> Int32 {
        switch error {
        case let gErr as GeminiError:
            switch gErr {
            case .apiKeyMissing: return 6
            case .rateLimited: return 8
            case .timeout: return 7
            case .invalidJSON: return 4
            case .imageTooLarge: return 2
            default: return 9
            }
        default: return 9
        }
    }
}
