import Foundation
import ArgumentParser
import GeminiDesignAgentCore

#if canImport(Darwin)
import Darwin
#endif

struct AuthCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auth",
        abstract: "Manage the Gemini API key in macOS Keychain",
        discussion: """
        Examples:
          gda auth onboard
          gda auth set
          gda auth status --json
          gda auth delete --json
        """,
        subcommands: [
            AuthOnboardCommand.self,
            AuthSetCommand.self,
            AuthStatusCommand.self,
            AuthDeleteCommand.self
        ]
    )
}

struct AuthOnboardCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "onboard",
        abstract: "Open a guided Gemini API key setup flow"
    )

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }

        do {
            guard !json, HiddenInput.isInteractiveTerminal else {
                throw authOnboardingInteractiveRequired()
            }

            print("Gemini Design Agent needs a Gemini API key before it can analyze screenshots.")
            print("")
            print("1. A browser window will open Google AI Studio API Keys.")
            print("2. Create or copy a Gemini API key.")
            print("3. Paste it here. Input is hidden and will be stored in macOS Keychain.")
            print("")

            openGoogleAIStudioAPIKeys()

            let key = try HiddenInput.readLine(prompt: "Paste Gemini API key: ")
            let store = KeychainAPIKeyStore()
            try store.save(key)

            guard (try store.load()) != nil else {
                throw CLIError(
                    code: "AUTH_ONBOARDING_VERIFY_FAILED",
                    title: "Gemini API key was not saved",
                    message: "The key was accepted but could not be read back from macOS Keychain.",
                    resolution: "Run `gda auth onboard` again, or repair Keychain access and retry.",
                    retryable: true,
                    suggestedCommand: "gda auth onboard",
                    exitCode: 1
                )
            }

            print("")
            print("Gemini API key saved to macOS Keychain.")
            print("Return to Codex and rerun the design analysis.")
        } catch {
            try handleAuthError(error, json: json, command: "auth.onboard")
        }
    }
}

struct AuthSetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Save the Gemini API key to macOS Keychain"
    )

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }

        do {
            guard !json else {
                throw CLIError(
                    code: "NON_INTERACTIVE_REQUIRED",
                    title: "Interactive input is required",
                    message: "`gda auth set --json` does not prompt because JSON stdout must stay machine-readable.",
                    resolution: "Run `gda auth set` in an interactive terminal without `--json`.",
                    retryable: false,
                    suggestedCommand: "gda auth set",
                    exitCode: 2
                )
            }

            let key = try HiddenInput.readLine(prompt: "Gemini API key: ")
            try KeychainAPIKeyStore().save(key)

            print("Gemini API key saved to macOS Keychain.")
        } catch {
            try handleAuthError(error, json: json)
        }
    }
}

struct AuthStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Check whether a Gemini API key is saved in macOS Keychain"
    )

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }

        do {
            let configured = try KeychainAPIKeyStore().load() != nil

            if json {
                CLIResponse.success(
                    command: "auth.status",
                    data: ["configured": configured],
                    nextActions: configured ? [] : [["label": "Start auth onboarding", "command": "gda auth onboard"]]
                )
            } else if configured {
                print("Gemini API key is configured in macOS Keychain.")
            } else {
                print("Gemini API key is not configured. Run `gda auth onboard`.")
            }
        } catch {
            try handleAuthError(error, json: json)
        }
    }
}

struct AuthDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete the Gemini API key from macOS Keychain"
    )

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }

        do {
            try KeychainAPIKeyStore().delete()

            if json {
                CLIResponse.success(
                    command: "auth.delete",
                    data: [
                        "configured": false,
                        "message": "Gemini API key removed from macOS Keychain"
                    ],
                    nextActions: [["label": "Start auth onboarding", "command": "gda auth onboard"]]
                )
            } else {
                print("Gemini API key removed from macOS Keychain.")
            }
        } catch {
            try handleAuthError(error, json: json)
        }
    }
}

private func handleAuthError(_ error: Error, json: Bool, command: String = "auth") throws -> Never {
    if json {
        CLIResponse.failure(command: command, error: error)
    } else {
        print("Error: \(error.localizedDescription)")
    }
    if let cli = error as? CLIError {
        throw ExitCode(cli.exitCode)
    }
    throw ExitCode(1)
}

enum HiddenInput {
    static var isInteractiveTerminal: Bool {
        #if canImport(Darwin)
        isatty(STDIN_FILENO) == 1
        #else
        false
        #endif
    }

    static func readLine(prompt: String) throws -> String {
        #if canImport(Darwin)
        guard isInteractiveTerminal else {
            throw CLIError("`gda auth set` requires an interactive terminal")
        }

        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else {
            throw CLIError("Unable to read terminal settings")
        }

        var hidden = original
        hidden.c_lflag &= ~tcflag_t(ECHO)

        print(prompt, terminator: "")
        fflush(stdout)

        guard tcsetattr(STDIN_FILENO, TCSANOW, &hidden) == 0 else {
            throw CLIError("Unable to hide terminal input")
        }
        defer {
            _ = tcsetattr(STDIN_FILENO, TCSANOW, &original)
            print("")
        }

        guard let value = Swift.readLine() else {
            throw CLIError("No API key entered")
        }
        return value
        #else
        throw CLIError("Keychain authentication is only supported on macOS")
        #endif
    }
}

private func authOnboardingInteractiveRequired() -> CLIError {
    CLIError(
        code: "AUTH_ONBOARDING_INTERACTIVE_REQUIRED",
        title: "Interactive auth onboarding is required",
        message: "`gda auth onboard` must run in an interactive terminal so the API key can be entered securely.",
        resolution: "Run `gda auth onboard` in Terminal, or use `gda auth set` if you already have a key.",
        retryable: false,
        suggestedCommand: "gda auth onboard",
        exitCode: 2
    )
}

private func openGoogleAIStudioAPIKeys() {
    #if canImport(Darwin)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["https://aistudio.google.com/app/apikey"]
    try? process.run()
    #endif
}
