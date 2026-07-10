import Foundation
import ArgumentParser
import GeminiDesignAgentCore

enum CLIResponse {
    static let schemaVersion = "1.0"

    static func success(
        command: String,
        data: Any = [:],
        diagnostics: [[String: Any]] = [],
        nextActions: [[String: Any]] = []
    ) {
        envelope(ok: true, command: command, data: data, diagnostics: diagnostics, nextActions: nextActions)
    }

    static func envelope(
        ok: Bool,
        command: String,
        data: Any = [:],
        diagnostics: [[String: Any]] = [],
        nextActions: [[String: Any]] = []
    ) {
        CLIUtils.printJSON([
            "ok": ok,
            "command": command,
            "schema_version": schemaVersion,
            "data": data,
            "diagnostics": diagnostics,
            "next_actions": nextActions
        ])
    }

    static func successEncodable<T: Encodable>(
        command: String,
        data: T,
        diagnostics: [[String: Any]] = [],
        nextActions: [[String: Any]] = []
    ) throws {
        success(
            command: command,
            data: try object(from: data),
            diagnostics: diagnostics,
            nextActions: nextActions
        )
    }

    static func failure(
        command: String,
        error: Error,
        runId: String? = nil,
        phase: String? = nil
    ) {
        let detail = CLIErrorDetail(error: error, runId: runId, phase: phase)
        var payload: [String: Any] = [
            "ok": false,
            "command": command,
            "schema_version": schemaVersion,
            "data": NSNull(),
            "diagnostics": [],
            "next_actions": detail.nextActions,
            "error": detail.asObject
        ]
        if let diagnostic = detail.diagnostic {
            payload["diagnostics"] = [diagnostic]
        }
        CLIUtils.printJSON(payload)
    }

    static func object<T: Encodable>(from value: T) throws -> Any {
        let data = try JSON.encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }
}

struct CLIError: Error, LocalizedError {
    let code: String
    let title: String
    let message: String
    let resolution: String
    let retryable: Bool
    let suggestedCommand: String?
    let exitCode: Int32

    init(_ message: String) {
        self.init(
            code: "CLI_ERROR",
            title: "Command failed",
            message: message,
            resolution: "Review the command input and retry.",
            retryable: false,
            suggestedCommand: nil,
            exitCode: 1
        )
    }

    init(
        code: String,
        title: String,
        message: String,
        resolution: String,
        retryable: Bool,
        suggestedCommand: String? = nil,
        exitCode: Int32 = 1
    ) {
        self.code = code
        self.title = title
        self.message = message
        self.resolution = resolution
        self.retryable = retryable
        self.suggestedCommand = suggestedCommand
        self.exitCode = exitCode
    }

    var errorDescription: String? { message }
}

private struct CLIErrorDetail {
    typealias ErrorMapping = (
        code: String,
        title: String,
        message: String,
        resolution: String,
        retryable: Bool,
        suggestedCommand: String?,
        exitCode: Int32,
        diagnostic: [String: Any]?
    )

    var code: String
    var title: String
    var message: String
    var resolution: String
    var retryable: Bool
    var suggestedCommand: String?
    var exitCode: Int32
    var runId: String?
    var phase: String?
    var diagnostic: [String: Any]?

    init(error: Error, runId: String?, phase: String?) {
        let effectiveError: Error
        let effectiveRunId: String?
        let effectivePhase: String?

        if let runFailure = error as? AnalyzeRunFailure {
            effectiveError = runFailure.underlying
            effectiveRunId = runFailure.runId
            effectivePhase = runFailure.phase
        } else {
            effectiveError = error
            effectiveRunId = runId
            effectivePhase = phase
        }

        let mapped: ErrorMapping
        if let cli = effectiveError as? CLIError {
            mapped = (
                cli.code,
                cli.title,
                cli.message,
                cli.resolution,
                cli.retryable,
                cli.suggestedCommand,
                cli.exitCode,
                nil
            )
        } else if let gemini = effectiveError as? GeminiError {
            mapped = Self.mapGemini(gemini)
        } else if let sqlite = effectiveError as? SQLError {
            mapped = Self.mapSQLite(sqlite)
        } else if effectiveError is ImageInfoReader.ImageError {
            mapped = (
                "IMAGE_READ_ERROR",
                "Could not inspect image",
                effectiveError.localizedDescription,
                "Use a valid PNG or JPEG screenshot and retry.",
                false,
                nil,
                2,
                nil
            )
        } else {
            mapped = (
                "INTERNAL_ERROR",
                "Internal error",
                effectiveError.localizedDescription,
                "Rerun with the same arguments. If this repeats, inspect `gda doctor --json`.",
                true,
                "gda doctor --json",
                9,
                nil
            )
        }

        self.code = mapped.code
        self.title = mapped.title
        self.message = mapped.message
        self.resolution = mapped.resolution
        self.retryable = mapped.retryable
        self.suggestedCommand = mapped.suggestedCommand
        self.exitCode = mapped.exitCode
        self.runId = effectiveRunId
        self.phase = effectivePhase
        self.diagnostic = mapped.diagnostic
    }

    var asObject: [String: Any] {
        var object: [String: Any] = [
            "code": code,
            "title": title,
            "message": message,
            "resolution": resolution,
            "retryable": retryable
        ]
        if let runId { object["run_id"] = runId }
        if let phase { object["phase"] = phase }
        if let suggestedCommand { object["suggested_command"] = suggestedCommand }
        return object
    }

    var nextActions: [[String: Any]] {
        guard let suggestedCommand else { return [] }
        return [["label": "Suggested command", "command": suggestedCommand]]
    }

    private static func mapGemini(_ error: GeminiError) -> (
        code: String,
        title: String,
        message: String,
        resolution: String,
        retryable: Bool,
        suggestedCommand: String?,
        exitCode: Int32,
        diagnostic: [String: Any]?
    ) {
        switch error {
        case .apiKeyMissing:
            return (
                "API_KEY_MISSING",
                "Gemini API key is missing",
                "Gemini API key is not configured.",
                "Run `gda auth onboard`, or `gda auth set` if you already have a key. Use GEMINI_API_KEY only for a temporary CI/debugging override.",
                false,
                "gda auth onboard",
                6,
                nil
            )
        case .rateLimited:
            return (
                "RATE_LIMITED",
                "Gemini rate limited the request",
                error.localizedDescription,
                "Wait and retry. If this is CI, reduce concurrency.",
                true,
                nil,
                8,
                nil
            )
        case .timeout:
            return (
                "TIMEOUT",
                "Gemini request timed out",
                error.localizedDescription,
                "Retry with a higher `--timeout-seconds` value.",
                true,
                nil,
                7,
                nil
            )
        case .networkUnavailable, .dnsFailure, .connectionFailed:
            return (
                "NETWORK_ERROR",
                "Gemini network request failed",
                error.localizedDescription,
                "Check network connectivity and DNS, then retry.",
                true,
                nil,
                7,
                nil
            )
        case .invalidJSON(let details):
            return (
                "INVALID_GEMINI_JSON",
                "Gemini returned invalid analysis JSON",
                error.localizedDescription,
                "Retry once. If it repeats, inspect the saved raw response and prompt artifacts.",
                true,
                "gda doctor --json",
                4,
                ["kind": "decode", "details": details]
            )
        case .imageTooLarge, .requestTooLarge:
            return (
                "REQUEST_TOO_LARGE",
                "Image request is too large for inline Gemini upload",
                error.localizedDescription,
                "Use a smaller screenshot or crop the image before analyzing.",
                false,
                nil,
                2,
                nil
            )
        case .contentBlocked(let reason):
            return (
                "CONTENT_BLOCKED",
                "Gemini blocked the content",
                error.localizedDescription,
                "Use a redacted screenshot or remove sensitive/blocked content before retrying.",
                false,
                nil,
                4,
                ["kind": "gemini_error_code", "code": reason]
            )
        case .noCandidates(let details):
            return (
                "NO_CANDIDATES",
                "Gemini returned no candidates",
                error.localizedDescription,
                "Retry once. If it repeats, inspect safety settings and screenshot content.",
                true,
                nil,
                4,
                ["kind": "gemini_response", "details": String(details.prefix(500))]
            )
        case .noTextOutput(let details):
            return (
                "NO_TEXT_OUTPUT",
                "Gemini returned no text output",
                error.localizedDescription,
                "Retry once. If it repeats, inspect the saved raw response and prompt artifacts.",
                true,
                nil,
                4,
                ["kind": "gemini_response", "details": String(details.prefix(500))]
            )
        case .interactionIncomplete(let details):
            return (
                "INTERACTION_INCOMPLETE",
                "Gemini interaction returned incomplete output",
                error.localizedDescription,
                "Retry with a narrower request or a larger output-token budget when available.",
                true,
                nil,
                4,
                ["kind": "gemini_status", "status": "incomplete", "details": details]
            )
        case .interactionFailed(let details):
            return (
                "INTERACTION_FAILED",
                "Gemini interaction failed",
                error.localizedDescription,
                "Retry once. If it repeats, inspect the saved raw response and prompt artifacts.",
                true,
                nil,
                4,
                ["kind": "gemini_status", "status": "failed", "details": String(details.prefix(500))]
            )
        case .interactionCancelled:
            return (
                "INTERACTION_CANCELLED",
                "Gemini interaction was cancelled",
                error.localizedDescription,
                "Rerun the analysis when the upstream service is available.",
                true,
                nil,
                4,
                ["kind": "gemini_status", "status": "cancelled"]
            )
        case .invalidSynchronousInteractionState:
            return (
                "INTERACTION_IN_PROGRESS",
                "Gemini interaction did not complete synchronously",
                error.localizedDescription,
                "Retry after the interaction reaches a terminal status.",
                false,
                nil,
                4,
                ["kind": "gemini_status", "status": "in_progress"]
            )
        case .unsupportedInteractionState(let state):
            return (
                "INTERACTION_STATE_UNSUPPORTED",
                "Gemini interaction returned an unsupported state",
                error.localizedDescription,
                "Retry the request without tools or background execution.",
                false,
                nil,
                4,
                ["kind": "gemini_status", "status": state]
            )
        case .quotaExhausted(let details):
            return (
                "QUOTA_EXHAUSTED",
                "Gemini quota is exhausted",
                error.localizedDescription,
                "Wait for quota reset or use a project/API key with available quota.",
                false,
                nil,
                8,
                ["kind": "http", "body_prefix": String(details.prefix(500))]
            )
        case .modelNotFound(let details):
            return (
                "MODEL_NOT_FOUND",
                "Gemini model was not found",
                error.localizedDescription,
                "Use a supported model such as `\(GDAContract.defaultModel)`.",
                false,
                nil,
                9,
                ["kind": "http", "body_prefix": String(details.prefix(500))]
            )
        case .billingDisabled(let details):
            return (
                "BILLING_DISABLED",
                "Gemini billing is disabled or unavailable",
                error.localizedDescription,
                "Enable billing or use an API key from a project with Gemini API access.",
                false,
                nil,
                6,
                ["kind": "http", "body_prefix": String(details.prefix(500))]
            )
        case .invalidAPIKey(let details):
            return (
                "INVALID_API_KEY",
                "Gemini API key was rejected",
                error.localizedDescription,
                "Run `gda auth onboard` with a valid key, or `gda auth set` if you already have one.",
                false,
                "gda auth onboard",
                6,
                ["kind": "http", "body_prefix": String(details.prefix(500))]
            )
        case .invalidURL:
            return (
                "INVALID_GEMINI_URL",
                "Gemini URL is invalid",
                error.localizedDescription,
                "Check the configured model name.",
                false,
                nil,
                9,
                nil
            )
        case .unexpectedResponse(let details):
            return (
                "UNEXPECTED_GEMINI_RESPONSE",
                "Gemini response was unexpected",
                error.localizedDescription,
                "Retry. If it repeats, inspect the raw response.",
                true,
                nil,
                9,
                ["kind": "gemini_response", "details": details]
            )
        case .httpError(let statusCode, let body):
            let code = statusCode == 401 ? "INVALID_API_KEY" : "GEMINI_HTTP_ERROR"
            let title = statusCode == 401 ? "Gemini API key was rejected" : "Gemini HTTP request failed"
            let resolution = statusCode == 401 ? "Run `gda auth onboard` with a valid key, or `gda auth set` if you already have one." : "Inspect the HTTP status and retry when the upstream issue is resolved."
            return (
                code,
                title,
                error.localizedDescription,
                resolution,
                statusCode >= 500,
                statusCode == 401 ? "gda auth onboard" : nil,
                statusCode == 401 ? 6 : 9,
                ["kind": "http", "status_code": statusCode, "body_prefix": String(body.prefix(500))]
            )
        }
    }

    private static func mapSQLite(_ error: SQLError) -> (
        code: String,
        title: String,
        message: String,
        resolution: String,
        retryable: Bool,
        suggestedCommand: String?,
        exitCode: Int32,
        diagnostic: [String: Any]?
    ) {
        let message = "\(error)"
        let lower = message.lowercased()
        if lower.contains("database is locked") || lower.contains("busy") {
            return ("DB_LOCKED", "Project database is locked", message, "Wait for the other `gda` process to finish and retry.", true, nil, 10, nil)
        }
        if lower.contains("disk") || lower.contains("full") || lower.contains("readonly") {
            return ("PROJECT_NOT_WRITABLE", "Project storage is not writable", message, "Free disk space or choose a writable `--project-dir`.", false, nil, 11, nil)
        }
        if lower.contains("malformed") || lower.contains("corrupt") {
            return ("DB_CORRUPT", "Project database may be corrupt", message, "Run `gda doctor --json` and consider backing up then resetting the project memory.", false, "gda doctor --json", 12, nil)
        }
        return ("SQLITE_ERROR", "SQLite operation failed", message, "Run `gda doctor --json` for project storage diagnostics.", false, "gda doctor --json", 9, nil)
    }
}
