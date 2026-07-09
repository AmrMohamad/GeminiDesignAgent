import Foundation
import ArgumentParser
import GeminiDesignAgentCore
import GDAPlatformSupport

struct AuthCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auth",
        abstract: "Manage the Gemini API key in the platform credential store",
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
            guard !json, TerminalInput.isInteractiveTerminal else {
                throw authOnboardingInteractiveRequired()
            }

            print("Gemini Design Agent needs a Gemini API key before it can analyze screenshots.")
            print("")
            print("1. A browser window will open Google AI Studio API Keys.")
            print("2. Create or copy a Gemini API key.")
            print("3. Paste it here. It will be stored in \(KeychainAPIKeyStore().persistenceDescription).")
            print("")

            openGoogleAIStudioAPIKeys()

            let key = try TerminalInput.readSecret(prompt: "Paste Gemini API key: ")
            let store = KeychainAPIKeyStore()
            try store.save(key)

            guard (try store.load()) != nil else {
                throw CLIError(
                    code: "AUTH_ONBOARDING_VERIFY_FAILED",
                    title: "Gemini API key was not saved",
                    message: "The key was accepted but could not be read back from \(store.persistenceDescription).",
                    resolution: "Run `gda auth onboard` again, or repair credential-store access and retry.",
                    retryable: true,
                    suggestedCommand: "gda auth onboard",
                    exitCode: 1
                )
            }

            print("")
            print("Gemini API key saved to \(store.persistenceDescription).")
            print("Return to Codex and rerun the design analysis.")
        } catch {
            try handleAuthError(error, json: json, command: "auth.onboard")
        }
    }
}

struct AuthSetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Save the Gemini API key to the platform credential store"
    )

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }

        do {
            guard !json, TerminalInput.isInteractiveTerminal else {
                throw authSetInteractiveRequired()
            }

            let key = try TerminalInput.readSecret(prompt: "Gemini API key: ")
            let store = KeychainAPIKeyStore()
            try store.save(key)

            print("Gemini API key saved to \(store.persistenceDescription).")
        } catch {
            try handleAuthError(error, json: json)
        }
    }
}

struct AuthStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Check whether a Gemini API key is saved in the platform credential store"
    )

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }

        do {
            let store = KeychainAPIKeyStore()
            let configured = try store.load() != nil

            if json {
                CLIResponse.success(
                    command: "auth.status",
                    data: [
                        "configured": configured,
                        "store": store.persistenceDescription
                    ],
                    nextActions: configured ? [] : [["label": "Start auth onboarding", "command": "gda auth onboard"]]
                )
            } else if configured {
                print("Gemini API key is configured in \(store.persistenceDescription).")
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
        abstract: "Delete the Gemini API key from the platform credential store"
    )

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }

        do {
            let store = KeychainAPIKeyStore()
            try store.delete()

            if json {
                CLIResponse.success(
                    command: "auth.delete",
                    data: [
                        "configured": false,
                        "message": "Gemini API key removed from \(store.persistenceDescription)"
                    ],
                    nextActions: [["label": "Start auth onboarding", "command": "gda auth onboard"]]
                )
            } else {
                print("Gemini API key removed from \(store.persistenceDescription).")
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

private func authSetInteractiveRequired() -> CLIError {
    CLIError(
        code: "AUTH_SET_INTERACTIVE_REQUIRED",
        title: "Interactive auth input is required",
        message: "`gda auth set` must run in an interactive terminal so the API key can be entered securely.",
        resolution: "Run `gda auth set` in Terminal without `--json`.",
        retryable: false,
        suggestedCommand: "gda auth set",
        exitCode: 2
    )
}

private func openGoogleAIStudioAPIKeys() {
    #if os(macOS)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["https://aistudio.google.com/app/apikey"]
    try? process.run()
    #endif
}
