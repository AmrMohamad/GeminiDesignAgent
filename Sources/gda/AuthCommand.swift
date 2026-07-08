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
        subcommands: [
            AuthSetCommand.self,
            AuthStatusCommand.self,
            AuthDeleteCommand.self
        ]
    )
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
            let key = try HiddenInput.readLine(prompt: "Gemini API key: ")
            try KeychainAPIKeyStore().save(key)

            if json {
                CLIUtils.printJSON([
                    "ok": true,
                    "configured": true,
                    "message": "Gemini API key saved to macOS Keychain"
                ])
            } else {
                print("Gemini API key saved to macOS Keychain.")
            }
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
                CLIUtils.printJSON([
                    "ok": true,
                    "configured": configured
                ])
            } else if configured {
                print("Gemini API key is configured in macOS Keychain.")
            } else {
                print("Gemini API key is not configured. Run `gda auth set`.")
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
                CLIUtils.printJSON([
                    "ok": true,
                    "configured": false,
                    "message": "Gemini API key removed from macOS Keychain"
                ])
            } else {
                print("Gemini API key removed from macOS Keychain.")
            }
        } catch {
            try handleAuthError(error, json: json)
        }
    }
}

private func handleAuthError(_ error: Error, json: Bool) throws -> Never {
    if json {
        CLIUtils.printJSON([
            "ok": false,
            "error": [
                "code": "AUTH_ERROR",
                "message": error.localizedDescription
            ]
        ])
    } else {
        print("Error: \(error.localizedDescription)")
    }
    throw ExitCode(1)
}

enum HiddenInput {
    static func readLine(prompt: String) throws -> String {
        #if canImport(Darwin)
        guard isatty(STDIN_FILENO) == 1 else {
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
