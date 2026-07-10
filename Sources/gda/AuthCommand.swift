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
          gda auth manage
          gda auth set
          gda auth status --json
          gda auth delete --json
          gda auth pool add --label work-project
          gda auth pool list --json
        """,
        subcommands: [
            AuthOnboardCommand.self,
            AuthSetCommand.self,
            AuthStatusCommand.self,
            AuthDeleteCommand.self,
            AuthManageCommand.self,
            AuthPoolCommand.self
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
            try await CLIUtils.withCredentialPoolLock {
                try APIKeyPoolCoordinator().savePrimary(key: key)
            }

            guard (try await CLIUtils.withCredentialPoolLock { try APIKeyPoolCoordinator().select() }) != nil else {
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

            try await addBackupsDuringOnboarding()
            let status = try await CLIUtils.withCredentialPoolLock { try APIKeyPoolCoordinator().status() }

            print("")
            print("Gemini API key saved to \(store.persistenceDescription).")
            print("\(status.configuredCount) \(status.configuredCount == 1 ? "key is" : "keys are") ready.")
            if status.configuredCount > 1 {
                print("Automatic backup is on. GDA uses a backup only when a project's quota is exhausted.")
            } else {
                print("Add a backup any time with `gda auth manage`.")
            }
            print("Use `gda auth manage` any time to add or manage backup keys.")
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
            try await CLIUtils.withCredentialPoolLock {
                try APIKeyPoolCoordinator().savePrimary(key: key)
            }

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
            let status = try await CLIUtils.withCredentialPoolLock { try APIKeyPoolCoordinator().status() }
            let configured = status.configuredCount > 0

            if json {
                CLIResponse.success(
                    command: "auth.status",
                    data: [
                        "configured": configured,
                        "store": store.persistenceDescription,
                        "pool_count": status.configuredCount,
                        "healthy_count": status.healthyCount,
                        "exhausted_count": status.exhaustedCount,
                        "active_label": status.activeLabel ?? NSNull(),
                        "earliest_recovery": status.earliestRecovery.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull()
                    ],
                    nextActions: configured ? [] : [["label": "Start auth onboarding", "command": "gda auth onboard"]]
                )
            } else if configured {
                print("Ready — \(status.configuredCount) \(status.configuredCount == 1 ? "key" : "keys") configured, \(status.healthyCount) available.")
                if status.configuredCount > 1 { print("  Automatic backup is on.") }
                else { print("  Add a backup any time with `gda auth manage`.") }
                if let activeLabel = status.activeLabel { print("  Using: \(activeLabel)") }
                if status.exhaustedCount > 0, let earliestRecovery = status.earliestRecovery {
                    print("  \(status.exhaustedCount) \(status.exhaustedCount == 1 ? "key is" : "keys are") waiting for quota reset at \(ISO8601DateFormatter().string(from: earliestRecovery)).")
                }
            } else {
                print("No Gemini API key is configured. Run `gda auth onboard` to get started.")
            }
        } catch {
            try handleAuthError(error, json: json)
        }
    }
}

struct AuthManageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "manage",
        abstract: "Interactively add and manage backup Gemini API keys"
    )

    func run() async throws {
        do {
            guard TerminalInput.isInteractiveTerminal else { throw authManageInteractiveRequired() }

            print("Manage Gemini API keys")
            print("Backup keys are used only when a project's Gemini quota is exhausted.")
            print("")

            while true {
                let entries = try await CLIUtils.withCredentialPoolLock {
                    try PlatformAPIKeyPoolStore().loadRegistry().entries.sorted { $0.priority < $1.priority }
                }
                printKeySummary(entries)
                print("")
                print("1. Add a backup key")
                print("2. Make a key first")
                print("3. Remove a key")
                print("4. Done")

                guard let choice = readInteractiveLine(prompt: "Choose an option [1-4]: ")?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    print("")
                    return
                }

                switch choice {
                case "1":
                    _ = try await addBackupKeyInteractively()
                case "2":
                    try await promoteKeyInteractively(entries: entries)
                case "3":
                    try await removeKeyInteractively(entries: entries)
                case "4", "":
                    return
                default:
                    print("Please choose 1, 2, 3, or 4.")
                }
                print("")
            }
        } catch {
            try handleAuthError(error, json: false, command: "auth.manage")
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
            let hasRemainingEntries = try await CLIUtils.withCredentialPoolLock {
                let coordinator = APIKeyPoolCoordinator()
                let hasFallback = try coordinator.store.loadRegistry().entries.contains { $0.id != "primary" }
                try coordinator.deletePrimary()
                return hasFallback
            }

            if json {
                CLIResponse.success(
                    command: "auth.delete",
                    data: [
                        "configured": hasRemainingEntries,
                        "message": "Primary Gemini API key removed from \(store.persistenceDescription)"
                    ],
                    nextActions: hasRemainingEntries ? [] : [["label": "Start auth onboarding", "command": "gda auth onboard"]]
                )
            } else {
                print("Primary Gemini API key removed from \(store.persistenceDescription).")
            }
        } catch {
            try handleAuthError(error, json: json)
        }
    }
}

struct AuthPoolCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pool",
        abstract: "Manage multiple Gemini API keys stored in secure platform credentials",
        subcommands: [
            AuthPoolAddCommand.self,
            AuthPoolListCommand.self,
            AuthPoolPromoteCommand.self,
            AuthPoolRemoveCommand.self,
            AuthPoolResetCommand.self
        ]
    )
}

struct AuthPoolAddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Add a Gemini API key to the secure pool")

    @Option(name: .long, help: "A non-secret label for this key's project")
    var label: String

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }
        do {
            guard !json, TerminalInput.isInteractiveTerminal else { throw authPoolInteractiveRequired() }
            let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedLabel.isEmpty, normalizedLabel.count <= 80, normalizedLabel.utf8.allSatisfy({ $0 >= 0x20 && $0 != 0x7F }) else {
                throw CLIError("Pool label must be 1-80 characters without control or newline characters.")
            }
            let key = try TerminalInput.readSecret(prompt: "Gemini API key for \(label): ")
            let entry = try await CLIUtils.withCredentialPoolLock {
                try APIKeyPoolCoordinator().add(key: key, label: normalizedLabel)
            }
            print("Gemini API key added as `\(entry.label)` (\(entry.id)).")
        } catch {
            try handleAuthError(error, json: json, command: "auth.pool.add")
        }
    }
}

struct AuthPoolListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List pool entries without displaying credentials")

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }
        do {
            let registry = try await CLIUtils.withCredentialPoolLock { try PlatformAPIKeyPoolStore().loadRegistry() }
            let now = Date()
            let entries = registry.entries.sorted { $0.priority < $1.priority }.map { entry in
                [
                    "id": entry.id,
                    "label": entry.label,
                    "priority": entry.priority,
                    "exhausted": entry.exhaustedUntil.map { $0 > now } ?? false,
                    "exhausted_until": entry.exhaustedUntil.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull()
                ] as [String: Any]
            }
            if json {
                CLIResponse.success(command: "auth.pool.list", data: ["entries": entries])
            } else if entries.isEmpty {
                print("Gemini API key pool is empty.")
            } else {
                for entry in entries {
                    let exhausted = (entry["exhausted"] as? Bool) == true ? " (exhausted)" : ""
                    print("\(entry["priority"] ?? "?"): \(entry["label"] ?? "") [\(entry["id"] ?? "")]\(exhausted)")
                }
            }
        } catch {
            try handleAuthError(error, json: json, command: "auth.pool.list")
        }
    }
}

struct AuthPoolPromoteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "promote", abstract: "Make a pool entry the primary fallback")

    @Argument(help: "Pool entry ID")
    var id: String

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }
        do {
            try await CLIUtils.withCredentialPoolLock { try APIKeyPoolCoordinator().promote(id: id) }
            if json { CLIResponse.success(command: "auth.pool.promote", data: ["id": id]) }
            else { print("Gemini API key pool entry \(id) is now primary.") }
        } catch {
            try handleAuthError(error, json: json, command: "auth.pool.promote")
        }
    }
}

struct AuthPoolRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove a pool entry and its secure credential")

    @Argument(help: "Pool entry ID")
    var id: String

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }
        do {
            try await CLIUtils.withCredentialPoolLock { try APIKeyPoolCoordinator().remove(id: id) }
            if json { CLIResponse.success(command: "auth.pool.remove", data: ["id": id]) }
            else { print("Gemini API key pool entry \(id) removed.") }
        } catch {
            try handleAuthError(error, json: json, command: "auth.pool.remove")
        }
    }
}

struct AuthPoolResetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reset", abstract: "Clear quota cooldowns")

    @Argument(help: "Pool entry ID; omit with --all")
    var id: String?

    @Flag(name: .long, help: "Reset every pool entry")
    var all: Bool = false

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }
        do {
            guard all || id != nil else { throw CLIError("Pass a pool entry ID or --all.") }
            guard !all || id == nil else { throw CLIError("Pass either a pool entry ID or --all, not both.") }
            try await CLIUtils.withCredentialPoolLock { try APIKeyPoolCoordinator().reset(id: all ? nil : id) }
            if json { CLIResponse.success(command: "auth.pool.reset", data: ["all": all, "id": id.map { $0 as Any } ?? NSNull()]) }
            else { print(all ? "All Gemini API key cooldowns reset." : "Gemini API key pool entry \(id ?? "") cooldown reset.") }
        } catch {
            try handleAuthError(error, json: json, command: "auth.pool.reset")
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

private func authPoolInteractiveRequired() -> CLIError {
    CLIError(
        code: "AUTH_POOL_INTERACTIVE_REQUIRED",
        title: "Interactive pool input is required",
        message: "`gda auth pool add` must run in an interactive terminal so the API key can be entered securely.",
        resolution: "Run `gda auth pool add --label <label>` in Terminal.",
        retryable: false,
        suggestedCommand: "gda auth pool add --label <label>",
        exitCode: 2
    )
}

private func authManageInteractiveRequired() -> CLIError {
    CLIError(
        code: "AUTH_MANAGE_INTERACTIVE_REQUIRED",
        title: "Interactive key management is required",
        message: "`gda auth manage` must run in an interactive terminal.",
        resolution: "Run `gda auth manage` in Terminal, or use `gda auth status --json` for automation.",
        retryable: false,
        suggestedCommand: "gda auth manage",
        exitCode: 2
    )
}

private func addBackupsDuringOnboarding() async throws {
    while shouldAddBackupKey() {
        _ = try await addBackupKeyInteractively()
    }
}

private func shouldAddBackupKey() -> Bool {
    print("")
    print("Add a backup key now? Add one only if it belongs to a different Google AI Studio project.")
    let answer = readInteractiveLine(prompt: "Add backup key? [y/N]: ")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return answer == "y" || answer == "yes"
}

@discardableResult
private func addBackupKeyInteractively() async throws -> APIKeyPoolEntry {
    print("")
    print("A browser window will open Google AI Studio API Keys for your backup project.")
    openGoogleAIStudioAPIKeys()
    let key = try TerminalInput.readSecret(prompt: "Paste backup Gemini API key: ")
    let entry = try await CLIUtils.withCredentialPoolLock {
        let coordinator = APIKeyPoolCoordinator()
        let registry = try coordinator.store.loadRegistry()
        let label = nextBackupLabel(in: registry.entries)
        return try coordinator.add(key: key, label: label)
    }
    print("Backup key added.")
    return entry
}

private func nextBackupLabel(in entries: [APIKeyPoolEntry]) -> String {
    let labels = Set(entries.map(\.label))
    var number = 1
    while labels.contains("Backup \(number)") {
        number += 1
    }
    return "Backup \(number)"
}

private func printKeySummary(_ entries: [APIKeyPoolEntry]) {
    guard !entries.isEmpty else {
        print("No keys are configured. Choose ‘Add a backup key’ to add one, or run `gda auth onboard` for the first key.")
        return
    }

    print("Configured keys:")
    for (index, entry) in entries.enumerated() {
        print("  \(index + 1). \(entry.label)\(index == 0 ? " (first)" : "")")
    }
}

private func promoteKeyInteractively(entries: [APIKeyPoolEntry]) async throws {
    guard !entries.isEmpty else {
        print("Add a key first.")
        return
    }
    guard let entry = selectEntry(entries, prompt: "Make which key first? [1-\(entries.count), Enter to cancel]: ") else { return }
    try await CLIUtils.withCredentialPoolLock { try APIKeyPoolCoordinator().promote(id: entry.id) }
    print("\(entry.label) will be tried first.")
}

private func removeKeyInteractively(entries: [APIKeyPoolEntry]) async throws {
    guard !entries.isEmpty else {
        print("No keys to remove.")
        return
    }
    guard let entry = selectEntry(entries, prompt: "Remove which key? [1-\(entries.count), Enter to cancel]: ") else { return }
    let confirmation = readInteractiveLine(prompt: "Remove \(entry.label)? This cannot be undone. [y/N]: ")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard confirmation == "y" || confirmation == "yes" else { return }
    try await CLIUtils.withCredentialPoolLock { try APIKeyPoolCoordinator().remove(id: entry.id) }
    print("\(entry.label) removed.")
}

private func selectEntry(_ entries: [APIKeyPoolEntry], prompt: String) -> APIKeyPoolEntry? {
    guard let input = readInteractiveLine(prompt: prompt)?.trimmingCharacters(in: .whitespacesAndNewlines), !input.isEmpty else { return nil }
    guard let index = Int(input), entries.indices.contains(index - 1) else {
        print("Please choose a number from 1 to \(entries.count).")
        return nil
    }
    return entries[index - 1]
}

private func readInteractiveLine(prompt: String) -> String? {
    print(prompt, terminator: "")
    return readLine()
}

private func openGoogleAIStudioAPIKeys() {
    #if os(macOS)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["https://aistudio.google.com/app/apikey"]
    try? process.run()
    #endif
}
