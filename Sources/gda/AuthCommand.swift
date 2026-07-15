import Foundation
import ArgumentParser
import GeminiDesignAgentCore
import GDAPlatformSupport

struct AuthCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auth",
        abstract: "Manage Google OAuth profiles (Gemini CLI / Code Assist quotas) and Gemini API keys",
        discussion: """
        Examples:
          gda auth onboard
          gda auth onboard --api-key
          gda auth login --mode code-assist
          gda auth login --mode public-oauth
          gda auth login --label work
          gda auth accounts list
          gda auth accounts use <profile-id>
          gda auth mode set code-assist
          gda auth usage
          gda auth model-policy set --preferred gemini-3-pro-preview --fallback gemini-3.5-flash
          gda auth manage
          gda auth set
          gda auth status --json
          gda auth delete --json
          gda auth pool add --label work-project
          gda auth pool list --json
          gda auth quota [--account <profile-id>]
        """,
        subcommands: [
            AuthOnboardCommand.self,
            AuthLoginCommand.self,
            AuthOAuthClientCommand.self,
            AuthAccountsCommand.self,
            AuthModeCommand.self,
            AuthUsageCommand.self,
            AuthModelPolicyCommand.self,
            AuthCreditPolicyCommand.self,
            AuthSetCommand.self,
            AuthStatusCommand.self,
            AuthDeleteCommand.self,
            AuthManageCommand.self,
            AuthPoolCommand.self,
            AuthQuotaCommand.self
        ]
    )
}

struct AuthOnboardCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "onboard",
        abstract: "Open Google sign-in using Gemini CLI identity, or set up an API key"
    )

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    @Flag(name: .long, help: "Use the API-key setup flow instead of opening Google sign-in")
    var apiKey: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }

        do {
            guard !json, TerminalInput.isInteractiveTerminal else {
                throw authOnboardingInteractiveRequired()
            }

            if !apiKey {
                let configuration = GeminiCLIOAuthClient.configuration
                print("Opening Google sign-in in your browser using Gemini CLI identity...")
                print("Complete sign-in there; GDA will finish automatically.")
                let profile = try await performGeminiCLILogin(configuration: configuration, label: nil)
                print("Signed in. Google OAuth profile `\(profile.label)` is active.")
                print("")

                do {
                    let userData = try await performCodeAssistOnboarding(profileID: profile.id)
                    await updateProfileCompanionProject(profileID: profile.id, projectID: userData.projectID, tierID: userData.userTier, tierName: userData.tierName)
                    await updateProfileCreditBalance(profileID: profile.id, credits: userData.availableCredits)
                    print("Code Assist tier: \(userData.tierName ?? userData.userTier)")
                    if let paidTier = userData.paidTierName { print("Paid tier: \(paidTier)") }
                } catch {
                    print("Warning: Code Assist onboarding failed: \(error.localizedDescription)")
                    print("You can still use the account; run `gda auth status` to check.")
                }
                return
            }

            print("Gemini Design Agent needs a Gemini API key before it can analyze screenshots.")
            print("")
            print("1. A browser window will open Google AI Studio API Keys.")
            print("2. Create or copy a Gemini API key.")
            print("3. Paste it here. It will be stored in \(KeychainAPIKeyStore().persistenceDescription).")
            print("")

            try openGoogleAIStudioAPIKeys()

            let key = try TerminalInput.readSecret(prompt: "Paste Gemini API key: ")
            let store = KeychainAPIKeyStore()
            try await CLIUtils.withCredentialPoolLock {
                let coordinator = APIKeyPoolCoordinator()
                try coordinator.savePrimary(key: key)
                try OAuthProfileStore().saveMode(.apiKey)
            }

            guard (try await CLIUtils.withCredentialPoolLock { try APIKeyPoolCoordinator().selectPreferred() }) != nil else {
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

            let status = try await CLIUtils.withCredentialPoolLock { try APIKeyPoolCoordinator().status() }

            print("")
            print("Gemini API key saved to \(store.persistenceDescription).")
            print("\(status.configuredCount) \(status.configuredCount == 1 ? "key is" : "keys are") ready.")
            print("The first key is used until you manually choose another with `gda auth pool promote`.")
            print("Use `gda auth manage` any time to add or manage API keys.")
            print("Return to Codex and rerun the design analysis.")
        } catch {
            try handleAuthError(error, json: json, command: "auth.onboard")
        }
    }
}

struct AuthLoginCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "login",
        abstract: "Open Google sign-in for Code Assist or the public Gemini API"
    )

    @Option(name: .long, help: "OAuth mode: code-assist or public-oauth")
    var mode: String = AuthenticationMode.codeAssist.rawValue

    @Option(name: .long, help: "Developer-only public OAuth desktop-client JSON to import before sign-in")
    var clientSecrets: String?

    @Option(name: .long, help: "Optional non-secret local label; GDA assigns one automatically when omitted")
    var label: String?

    @Flag(name: .long, help: "Output JSON only after interactive sign-in completes")
    var json: Bool = false

    @Flag(name: .long, help: "Skip Code Assist onboarding after sign-in")
    var skipOnboarding: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }
        do {
            guard TerminalInput.isInteractiveTerminal else { throw authOAuthInteractiveRequired() }
            guard let selectedMode = AuthenticationMode(rawValue: mode),
                  selectedMode == .codeAssist || selectedMode == .publicOAuth else {
                throw CLIError("OAuth login mode must be `code-assist` or `public-oauth`.")
            }
            let configuration = if selectedMode == .codeAssist {
                GeminiCLIOAuthClient.configuration
            } else {
                try await resolveOAuthClientConfiguration(clientSecrets: clientSecrets)
            }
            if !json {
                let identity = selectedMode == .codeAssist ? "Gemini CLI identity" : "GDA's public Gemini OAuth client"
                print("Opening Google sign-in in your browser using \(identity)...")
                print("Complete sign-in there; GDA will finish automatically.")
            }
            let profile = if selectedMode == .codeAssist {
                try await performGeminiCLILogin(configuration: configuration, label: label)
            } else {
                try await performOAuthLogin(configuration: configuration, label: label)
            }

            if selectedMode == .codeAssist, !skipOnboarding {
                do {
                    let userData = try await performCodeAssistOnboarding(profileID: profile.id)
                    await updateProfileCompanionProject(profileID: profile.id, projectID: userData.projectID, tierID: userData.userTier, tierName: userData.tierName)
                    await updateProfileCreditBalance(profileID: profile.id, credits: userData.availableCredits)
                    if !json {
                        print("Code Assist tier: \(userData.tierName ?? userData.userTier)")
                        if let paidTier = userData.paidTierName { print("Paid tier: \(paidTier)") }
                    }
                } catch {
                    if !json { print("Warning: Code Assist setup failed: \(error.localizedDescription)") }
                }
            }

            if json {
                let summary = try await CLIUtils.withCredentialPoolLock {
                    try OAuthProfileStore().profileSummaries().first(where: { $0.id == profile.id })
                }
                try CLIResponse.successEncodable(command: "auth.login", data: summary ?? OAuthProfileSummary(
                    id: profile.id,
                    label: profile.label,
                    backend: .codeAssist,
                    companionProjectID: profile.companionProjectID,
                    maskedEmail: "unavailable",
                    tokenState: "valid",
                    hasOnboarded: profile.hasOnboarded,
                    tierName: profile.tierName,
                    isActive: true
                ))
            } else {
                print("Signed in for \(selectedMode.rawValue). Google OAuth profile `\(profile.label)` is active.")
                print("Use `gda auth accounts list` to view masked account metadata.")
                if selectedMode == .codeAssist { print("Use `gda auth quota` to check your Code Assist quota.") }
            }
        } catch {
            try handleAuthError(error, json: json, command: "auth.login")
        }
    }
}

struct AuthOAuthClientCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "oauth-client",
        abstract: "Provision the GDA-owned desktop OAuth client for this installation",
        subcommands: [AuthOAuthClientImportCommand.self, AuthOAuthClientStatusCommand.self]
    )
}

struct AuthOAuthClientImportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Import and securely remember GDA's installed-app OAuth client configuration"
    )

    @Option(name: .long, help: "Path to a Google desktop OAuth client JSON containing an installed client")
    var clientSecrets: String

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }
        do {
            let url = URL(fileURLWithPath: clientSecrets)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw CLIError("OAuth client JSON was not found at the supplied path.")
            }
            let configuration = try await CLIUtils.withCredentialPoolLock {
                try OAuthClientConfigurationResolver().importConfiguration(from: url)
            }
            if json {
                CLIResponse.success(
                    command: "auth.oauth-client.import",
                    data: ["configured": true, "project_id": configuration.projectID]
                )
            } else {
                print("GDA OAuth client configured securely for project `\(configuration.projectID)`.")
                print("Run `gda auth login`; the browser will open automatically.")
            }
        } catch {
            try handleAuthError(error, json: json, command: "auth.oauth-client.import")
        }
    }
}

struct AuthOAuthClientStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Check whether this GDA installation has an OAuth client configured"
    )

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }
        do {
            let resolver = OAuthClientConfigurationResolver()
            let configuration = try await CLIUtils.withCredentialPoolLock { try resolver.configured() }
            if json {
                CLIResponse.success(
                    command: "auth.oauth-client.status",
                    data: [
                        "configured": configuration != nil,
                        "project_id": configuration?.projectID ?? NSNull(),
                        "store": resolver.persistenceDescription
                    ]
                )
            } else if let configuration {
                print("GDA OAuth client is configured for project `\(configuration.projectID)`.")
            } else {
                print("This GDA installation does not have an OAuth client configured.")
            }
        } catch {
            try handleAuthError(error, json: json, command: "auth.oauth-client.status")
        }
    }
}

struct AuthAccountsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "accounts",
        abstract: "List, select, or remove GDA-owned Google OAuth profiles",
        subcommands: [AuthAccountsListCommand.self, AuthAccountsUseCommand.self, AuthAccountsRemoveCommand.self]
    )
}

struct AuthAccountsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List OAuth profiles without exposing identities or tokens")

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }
        do {
            let profiles = try await CLIUtils.withCredentialPoolLock { try OAuthProfileStore().profileSummaries() }
            if json {
                try CLIResponse.successEncodable(command: "auth.accounts.list", data: profiles)
            } else if profiles.isEmpty {
                print("No Google OAuth profiles are configured.")
            } else {
                for profile in profiles {
                    print("\(profile.isActive ? "*" : " ") \(profile.id)  \(profile.label)  \(profile.maskedEmail)  \(profile.tokenState)")
                }
            }
        } catch {
            try handleAuthError(error, json: json, command: "auth.accounts.list")
        }
    }
}

struct AuthAccountsUseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "use", abstract: "Select the active OAuth profile manually")

    @Argument(help: "OAuth profile UUID")
    var profileID: String

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }
        do {
            let profile = try await CLIUtils.withCredentialPoolLock {
                let store = OAuthProfileStore()
                let selected = try store.select(profileID: profileID)
                try store.saveMode(AuthenticationMode(backend: selected.backend))
                return selected
            }
            if json { try CLIResponse.successEncodable(command: "auth.accounts.use", data: ["id": profile.id, "label": profile.label]) }
            else { print("Active Google OAuth profile: \(profile.label)") }
        } catch {
            try handleAuthError(error, json: json, command: "auth.accounts.use")
        }
    }
}

struct AuthAccountsRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Revoke a Google OAuth profile, then remove it locally")

    @Argument(help: "OAuth profile UUID")
    var profileID: String

    @Flag(name: .long, help: "Delete local credentials without remote revocation; use only when revocation is unavailable")
    var localOnly: Bool = false

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }
        do {
            let profile = try await CLIUtils.withCredentialPoolLock {
                let store = OAuthProfileStore()
                let resolved = try store.profile(id: profileID)
                if !localOnly {
                    try await OAuthRevoker().revoke(refreshToken: resolved.1.tokens.refreshToken)
                }
                try store.remove(profileID: profileID)
                return resolved.0
            }
            if json { CLIResponse.success(command: "auth.accounts.remove", data: ["id": profile.id, "local_only": localOnly]) }
            else { print("Google OAuth profile `\(profile.label)` removed\(localOnly ? " locally only" : " after remote revocation").") }
        } catch {
            try handleAuthError(error, json: json, command: "auth.accounts.remove")
        }
    }
}

struct AuthModeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mode", abstract: "Select the persistent authentication method", subcommands: [AuthModeSetCommand.self])
}

struct AuthModeSetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Set code-assist, public-oauth, or api-key as the persistent authentication method")

    @Argument(help: "code-assist, public-oauth, or api-key")
    var mode: String

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }
        do {
            guard let selected = AuthenticationMode(rawValue: mode), selected != .oauth else {
                throw CLIError("Authentication mode must be `code-assist`, `public-oauth`, or `api-key`.")
            }
            try await CLIUtils.withCredentialPoolLock {
                let profileStore = OAuthProfileStore()
                switch selected {
                case .codeAssist, .publicOAuth:
                    guard let profile = try profileStore.activeProfile()?.0,
                          profile.backend == selected.backend else {
                        throw OAuthError.profileNotFound
                    }
                case .oauth:
                    preconditionFailure("Legacy OAuth mode is not user-selectable")
                case .apiKey:
                    guard try APIKeyPoolCoordinator().selectPreferred() != nil else { throw GeminiError.apiKeyMissing }
                }
                try profileStore.saveMode(selected)
            }
            if json { CLIResponse.success(command: "auth.mode.set", data: ["method": selected.rawValue]) }
            else { print("Persistent authentication method: \(selected.rawValue)") }
        } catch {
            try handleAuthError(error, json: json, command: "auth.mode.set")
        }
    }
}

struct AuthUsageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "usage", abstract: "Show locally observed OAuth activity, not remaining quota")

    @Option(name: .long, help: "OAuth profile UUID; defaults to the active profile")
    var account: String?

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }
        do {
            let profileID: String? = try await CLIUtils.withCredentialPoolLock { () throws -> String? in
                if let account {
                    _ = try OAuthProfileStore().profile(id: account)
                    return account
                }
                return try OAuthProfileStore().activeProfile()?.0.id
            }
            let usage = try await OAuthUsageLedger().observedUsage(profileID: profileID)
            if json {
                let entries: [Any] = try usage.map { try CLIResponse.object(from: $0) }
                let accountValue: Any = profileID ?? NSNull()
                CLIResponse.success(command: "auth.usage", data: ["observed": true, "account": accountValue, "entries": entries])
            } else if usage.isEmpty {
                print("No observed OAuth usage has been recorded.")
            } else {
                print("Observed local usage — not remaining quota:")
                for entry in usage {
                    print("\(entry.pacificDay) \(entry.model): \(entry.successes)/\(entry.attempts) successful, \(entry.totalTokens) tokens")
                }
            }
        } catch {
            try handleAuthError(error, json: json, command: "auth.usage")
        }
    }
}

struct AuthModelPolicyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "model-policy",
        abstract: "Manage explicit same-account model fallback chains",
        subcommands: [AuthModelPolicySetCommand.self, AuthModelPolicyShowCommand.self, AuthModelPolicyResetCommand.self]
    )
}

struct AuthCreditPolicyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "credit-policy",
        abstract: "Control whether Code Assist may spend Google One AI credits",
        subcommands: [AuthCreditPolicySetCommand.self, AuthCreditPolicyShowCommand.self, AuthCreditPolicyResetCommand.self]
    )
}

struct AuthCreditPolicySetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Set never, ask, or always for an OAuth profile")

    @Argument(help: "never, ask, or always")
    var policy: String

    @Option(name: .long, help: "OAuth profile UUID; defaults to active")
    var account: String?

    func run() async throws {
        do {
            guard let value = CreditPolicy(rawValue: policy) else { throw CLIError("Credit policy must be `never`, `ask`, or `always`.") }
            let profile = try await updateOAuthCreditPolicy(account: account, policy: value)
            print("Credit policy for \(profile.label): \(value.rawValue)")
        } catch {
            try handleAuthError(error, json: false, command: "auth.credit-policy.set")
        }
    }
}

struct AuthCreditPolicyShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Show an OAuth profile's credit policy and observed balance")

    @Option(name: .long, help: "OAuth profile UUID; defaults to active")
    var account: String?

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }
        do {
            let profile = try await selectedOAuthProfile(account: account)
            if json {
                CLIResponse.success(command: "auth.credit-policy.show", data: [
                    "policy": profile.creditPolicy.rawValue,
                    "google_one_ai_credit_balance": profile.googleOneAICreditBalance.map { $0 as Any } ?? NSNull()
                ])
            } else {
                print("\(profile.creditPolicy.rawValue) (Google One AI balance: \(profile.googleOneAICreditBalance.map(String.init) ?? "unknown"))")
            }
        } catch {
            try handleAuthError(error, json: json, command: "auth.credit-policy.show")
        }
    }
}

struct AuthCreditPolicyResetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reset", abstract: "Reset credit spending to never")

    @Option(name: .long, help: "OAuth profile UUID; defaults to active")
    var account: String?

    func run() async throws {
        do {
            let profile = try await updateOAuthCreditPolicy(account: account, policy: .never)
            print("Credit policy for \(profile.label) reset to never.")
        } catch {
            try handleAuthError(error, json: false, command: "auth.credit-policy.reset")
        }
    }
}

struct AuthModelPolicySetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Set a preferred model and optional explicit fallbacks")

    @Option(name: .long, help: "Preferred model")
    var preferred: String

    @Option(name: .long, help: "Fallback model; may be repeated")
    var fallback: [String] = []

    @Option(name: .long, help: "OAuth profile UUID; defaults to active")
    var account: String?

    func run() async throws {
        do {
            let policy = try makeOAuthModelPolicy(preferred: preferred, fallbacks: fallback)
            let profile = try await updateOAuthModelPolicy(account: account, policy: policy)
            print("Model policy for \(profile.label): \(policy.preferred)\(policy.fallbacks.isEmpty ? "" : " -> \(policy.fallbacks.joined(separator: ", "))")")
        } catch {
            try handleAuthError(error, json: false, command: "auth.model-policy.set")
        }
    }
}

struct AuthModelPolicyShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Show the active profile's model policy")

    @Option(name: .long, help: "OAuth profile UUID; defaults to active")
    var account: String?

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }
        do {
            let profile = try await selectedOAuthProfile(account: account)
            if json { try CLIResponse.successEncodable(command: "auth.model-policy.show", data: profile.modelPolicy) }
            else { print("\(profile.modelPolicy.preferred)\(profile.modelPolicy.fallbacks.isEmpty ? "" : " -> \(profile.modelPolicy.fallbacks.joined(separator: ", "))")") }
        } catch {
            try handleAuthError(error, json: json, command: "auth.model-policy.show")
        }
    }
}

struct AuthModelPolicyResetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reset", abstract: "Reset a model policy to gemini-3.5-flash with no fallback")

    @Option(name: .long, help: "OAuth profile UUID; defaults to active")
    var account: String?

    func run() async throws {
        do {
            let profile = try await updateOAuthModelPolicy(account: account, policy: .default)
            print("Model policy for \(profile.label) reset to \(OAuthModelPolicy.default.preferred) with no fallback.")
        } catch {
            try handleAuthError(error, json: false, command: "auth.model-policy.reset")
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
                let coordinator = APIKeyPoolCoordinator()
                try coordinator.savePrimary(key: key)
                try OAuthProfileStore().saveMode(.apiKey)
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
        abstract: "Check API-key and Google OAuth authentication readiness"
    )

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }

        do {
            let store = KeychainAPIKeyStore()
            let snapshot = try await CLIUtils.withCredentialPoolLock { () throws -> (APIKeyPoolStatus, AuthenticationMode?, OAuthProfile?, OAuthProfileSummary?, OAuthClientConfiguration?) in
                let profileStore = OAuthProfileStore()
                let active = try profileStore.activeProfile()?.0
                let summary = try profileStore.profileSummaries().first { $0.id == active?.id }
                let oauthClient = try OAuthClientConfigurationResolver().configured()
                return (try APIKeyPoolCoordinator().status(), try profileStore.loadMode(), active, summary, oauthClient)
            }
            let status = snapshot.0
            let activeOAuth = snapshot.2
            let activeSummary = snapshot.3
            let oauthClient = snapshot.4
            let selectedMode = snapshot.1 ?? (status.configuredCount > 0
                ? .apiKey
                : activeOAuth.map { AuthenticationMode(backend: $0.backend) } ?? .apiKey)
            let method = selectedMode.rawValue
            let configured: Bool
            if let backend = selectedMode.backend {
                configured = activeOAuth?.backend == backend
            } else {
                configured = status.configuredCount > 0
            }
            let observedUsage = try await OAuthUsageLedger().observedUsage(profileID: activeOAuth?.id)

            if json {
                let activeObject: Any
                if let activeSummary { activeObject = try CLIResponse.object(from: activeSummary) }
                else { activeObject = NSNull() }
                let modelPolicy: Any
                if let activeOAuth { modelPolicy = try CLIResponse.object(from: activeOAuth.modelPolicy) }
                else { modelPolicy = NSNull() }
                let observed: [Any] = try observedUsage.map { try CLIResponse.object(from: $0) }
                CLIResponse.success(
                    command: "auth.status",
                    data: [
                        "configured": configured,
                        "store": store.persistenceDescription,
                        "pool_count": status.configuredCount,
                        "healthy_count": status.healthyCount,
                        "exhausted_count": status.exhaustedCount,
                        "active_label": status.activeLabel ?? NSNull(),
                        "earliest_recovery": status.earliestRecovery.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
                        "method": method,
                        "active_profile": activeObject,
                        "token_state": activeSummary?.tokenState ?? NSNull(),
                        "model_policy": modelPolicy,
                        "observed_usage": observed,
                        "oauth_client_configured": oauthClient != nil,
                        "oauth_client_project_id": oauthClient?.projectID ?? NSNull()
                    ],
                    nextActions: configured ? [] : (oauthClient == nil
                        ? [["label": "Use API key instead", "command": "gda auth onboard --api-key"]]
                        : [["label": "Sign in with Google", "command": "gda auth onboard"]])
                )
            } else if selectedMode.isOAuth, configured, let activeSummary {
                print("Ready — \(method) profile \(activeSummary.label) is selected (\(activeSummary.maskedEmail)).")
                print("  Token state: \(activeSummary.tokenState).")
                print("  Model policy: \(activeOAuth?.modelPolicy.preferred ?? GDAContract.defaultModel).")
            } else if configured {
                print("Ready — \(status.configuredCount) \(status.configuredCount == 1 ? "key" : "keys") configured, \(status.healthyCount) available.")
                if status.configuredCount > 1 { print("  The first key is selected manually; no quota-driven rotation occurs.") }
                else { print("  Add another key any time with `gda auth manage`.") }
                if let activeLabel = status.activeLabel { print("  Using: \(activeLabel)") }
                if status.exhaustedCount > 0, let earliestRecovery = status.earliestRecovery {
                    print("  \(status.exhaustedCount) \(status.exhaustedCount == 1 ? "key is" : "keys are") waiting for quota reset at \(ISO8601DateFormatter().string(from: earliestRecovery)).")
                }
            } else {
                if oauthClient == nil {
                    print("Google sign-in is unavailable because this GDA installation was not provisioned for OAuth.")
                    print("  End users should not need an OAuth client JSON file.")
                    print("  Install an OAuth-ready GDA build, or use `gda auth onboard --api-key`.")
                } else {
                    print("No Google account or Gemini API key is configured. Run `gda auth onboard` to sign in.")
                }
            }
        } catch {
            try handleAuthError(error, json: json)
        }
    }
}

struct AuthManageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "manage",
        abstract: "Interactively add and prioritize Gemini API keys"
    )

    func run() async throws {
        do {
            guard TerminalInput.isInteractiveTerminal else { throw authManageInteractiveRequired() }

            print("Manage Gemini API keys")
            print("Keys are selected manually by priority; GDA never rotates projects on quota errors.")
            print("")

            while true {
                let entries = try await CLIUtils.withCredentialPoolLock {
                    try PlatformAPIKeyPoolStore().loadRegistry().entries.sorted { $0.priority < $1.priority }
                }
                printKeySummary(entries)
                print("")
                print("1. Add an API key")
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
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Add a manually selectable Gemini API key to the secure pool")

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
    static let configuration = CommandConfiguration(commandName: "promote", abstract: "Make a pool entry the manually selected first key")

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

struct AuthQuotaCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quota",
        abstract: "Check Code Assist quota for your Google accounts"
    )

    @Option(name: .long, help: "OAuth profile UUID; defaults to all profiles")
    var account: String?

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }
        do {
            let profileIDs: [String]
            if let account {
                profileIDs = [account]
            } else {
                let profiles = try await CLIUtils.withCredentialPoolLock { try OAuthProfileStore().profileSummaries() }
                profileIDs = profiles.filter {
                    $0.backend == .codeAssist && $0.tokenState == "valid" && ($0.companionProjectID ?? "") != "gemini-cli-project"
                }.map(\.id)
            }

            guard !profileIDs.isEmpty else {
                if json {
                    CLIResponse.success(command: "auth.quota", data: ["accounts": 0, "quotas": [String: Any]()])
                } else {
                    print("No accounts with completed Code Assist setup. Run `gda auth login` first.")
                }
                return
            }

            let quotaManager = AccountQuotaManager()
            try await quotaManager.loadAccounts()
            var results: [String: Any] = [:]
            for profileID in profileIDs {
                do {
                    let quotas = try await quotaManager.refreshQuota(profileID: profileID)
                    var modelData: [String: Any] = [:]
                    for (modelID, buckets) in quotas {
                        modelData[modelID] = buckets.map { quota -> [String: Any] in
                            var entry: [String: Any] = [:]
                            entry["remaining_amount"] = quota.remainingAmount ?? NSNull()
                            entry["remaining_fraction"] = quota.remainingFraction ?? NSNull()
                            entry["reset_time"] = quota.resetTime.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull()
                            entry["token_type"] = quota.tokenType ?? NSNull()
                            return entry
                        }
                    }
                    let store = OAuthProfileStore()
                    let profile = try await CLIUtils.withCredentialPoolLock { try store.profile(id: profileID).0 }
                    results[profileID] = ["label": profile.label, "models": modelData]
                } catch {
                    results[profileID] = ["error": error.localizedDescription]
                }
            }

            if json {
                CLIResponse.success(command: "auth.quota", data: ["accounts": results.count, "quotas": results])
            } else {
                for (profileID, data) in results {
                    if let dict = data as? [String: Any],
                       let label = dict["label"] as? String,
                       let models = dict["models"] as? [String: Any] {
                        print("\(label) (\(profileID)):")
                        if models.isEmpty {
                            print("  No quota data available")
                        }
                        for (modelID, quotaData) in models.sorted(by: { $0.key < $1.key }) {
                            if let qdict = quotaData as? [String: Any] {
                                let fraction = qdict["remaining_fraction"] as? Double
                                var status = ""
                                if let fraction {
                                    status = String(format: "%.0f%%", fraction * 100)
                                } else if let amount = qdict["remaining_amount"] as? String {
                                    status = amount
                                } else {
                                    status = "unknown"
                                }
                                print("  \(modelID): \(status)")
                            }
                        }
                    } else if let dict = data as? [String: Any], let error = dict["error"] as? String {
                        print("Error for \(profileID): \(error)")
                    }
                }
            }
        } catch {
            try handleAuthError(error, json: json, command: "auth.quota")
        }
    }
}

private func handleAuthError(_ error: Error, json: Bool, command: String = "auth") throws -> Never {
    if json {
        CLIResponse.failure(command: command, error: error)
    } else if let cli = error as? CLIError {
        print("Error: \(cli.title)")
        if cli.message != cli.title { print(cli.message) }
        if !cli.resolution.isEmpty { print("Next: \(cli.resolution)") }
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
        message: "`gda auth onboard` must run in an interactive terminal so GDA can open Google sign-in or accept an API key securely.",
        resolution: "Run `gda auth onboard` in Terminal. Use `gda auth onboard --api-key` only when you prefer an API key.",
        retryable: false,
        suggestedCommand: "gda auth onboard",
        exitCode: 2
    )
}

private func authOAuthInteractiveRequired() -> CLIError {
    CLIError(
        code: "AUTH_OAUTH_INTERACTIVE_REQUIRED",
        title: "Interactive Google sign-in is required",
        message: "`gda auth login` must run in an interactive terminal so GDA can open the system browser and receive the loopback callback.",
        resolution: "Run `gda auth login` in a local terminal; GDA will open the browser automatically.",
        retryable: false,
        suggestedCommand: "gda auth login",
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
    print("Add another API key now? It will be used only after you manually promote it.")
    let answer = readInteractiveLine(prompt: "Add API key? [y/N]: ")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return answer == "y" || answer == "yes"
}

@discardableResult
private func addBackupKeyInteractively() async throws -> APIKeyPoolEntry {
    print("")
    print("A browser window will open Google AI Studio API Keys.")
    try openGoogleAIStudioAPIKeys()
    let key = try TerminalInput.readSecret(prompt: "Paste Gemini API key: ")
    let entry = try await CLIUtils.withCredentialPoolLock {
        let coordinator = APIKeyPoolCoordinator()
        let registry = try coordinator.store.loadRegistry()
        let label = nextBackupLabel(in: registry.entries)
        return try coordinator.add(key: key, label: label)
    }
    print("API key added.")
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

private func openGoogleAIStudioAPIKeys() throws {
    guard let url = URL(string: "https://aistudio.google.com/app/apikey") else { throw GeminiError.invalidURL }
    try SystemOAuthBrowser().open(url)
}

private func updateProfileCompanionProject(profileID: String, projectID: String, tierID: String?, tierName: String?) async {
    _ = try? await CLIUtils.withCredentialPoolLock {
        let store = OAuthProfileStore()
        _ = try store.updateCompanionProject(profileID: profileID, projectID: projectID, tierID: tierID, tierName: tierName)
    }
}

private func updateProfileCreditBalance(profileID: String, credits: [CodeAssist.Credits]?) async {
    let matching = credits?.filter { $0.creditType == CodeAssist.CreditType.googleOneAI.rawValue } ?? []
    guard !matching.isEmpty else { return }
    let balance = matching.reduce(0) { $0 + (Int($1.creditAmount) ?? 0) }
    _ = try? await CLIUtils.withCredentialPoolLock {
        try OAuthProfileStore().updateGoogleOneAICreditBalance(profileID: profileID, balance: balance)
    }
}

private func performOAuthLogin(configuration: OAuthClientConfiguration, label: String?) async throws -> OAuthProfile {
    let normalizedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let normalizedLabel {
        guard !normalizedLabel.isEmpty,
              normalizedLabel.count <= 80,
              normalizedLabel.utf8.allSatisfy({ $0 >= 0x20 && $0 != 0x7F }) else {
            throw CLIError("OAuth profile label must be 1-80 characters without control characters.")
        }
    }

    let listener = try PlatformOAuthCallbackListener()
    let tokens = try await OAuthAuthorizationFlow().signIn(
        configuration: configuration,
        listener: listener,
        backend: .publicGeminiAPI
    )
    return try await CLIUtils.withCredentialPoolLock {
        let store = OAuthProfileStore()
        let profile = try store.upsert(label: normalizedLabel, backend: .publicGeminiAPI, configuration: configuration, tokens: tokens)
        try store.saveMode(.publicOAuth)
        return profile
    }
}

private func performGeminiCLILogin(configuration: OAuthClientConfiguration, label: String?) async throws -> OAuthProfile {
    let normalizedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let normalizedLabel {
        guard !normalizedLabel.isEmpty,
              normalizedLabel.count <= 80,
              normalizedLabel.utf8.allSatisfy({ $0 >= 0x20 && $0 != 0x7F }) else {
            throw CLIError("OAuth profile label must be 1-80 characters without control characters.")
        }
    }

    let listener = try PlatformOAuthCallbackListener(callbackPath: GeminiCLIOAuthClient.redirectPath)
    let tokens = try await OAuthAuthorizationFlow().signIn(
        configuration: configuration,
        listener: listener,
        backend: .codeAssist
    )
    return try await CLIUtils.withCredentialPoolLock {
        let store = OAuthProfileStore()
        let profile = try store.upsert(label: normalizedLabel, backend: .codeAssist, configuration: configuration, tokens: tokens)
        try store.saveMode(.codeAssist)
        return profile
    }
}

private func performCodeAssistOnboarding(profileID: String) async throws -> CodeAssistUserData {
    guard try await CLIUtils.withCredentialPoolLock({
        try OAuthProfileStore().loadSecret(profileID: profileID) != nil
    }) else {
        throw OAuthError.profileNotFound
    }

    let authorizer = OAuthTokenManager(profileID: profileID)
    let client = CodeAssistClient(authorizer: authorizer, projectID: nil)
    let setup = CodeAssistSetup(client: client)
    return try await setup.setupUser(profileID: profileID)
}

private func resolveOAuthClientConfiguration(clientSecrets: String?) async throws -> OAuthClientConfiguration {
    try await CLIUtils.withCredentialPoolLock {
        let resolver = OAuthClientConfigurationResolver()
        if let clientSecrets {
            let path = clientSecrets.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, !path.contains("<"), !path.contains(">") else {
                throw CLIError(
                    code: "OAUTH_CLIENT_PATH_PLACEHOLDER",
                    title: "Replace the example OAuth client path",
                    message: "`<desktop-client.json>` is documentation placeholder text, not a real file.",
                    resolution: "This developer-only option needs the actual downloaded desktop OAuth JSON path. End users should run `gda auth login` without `--client-secrets`.",
                    retryable: false,
                    exitCode: 2
                )
            }
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw CLIError(
                    code: "OAUTH_CLIENT_FILE_NOT_FOUND",
                    title: "OAuth client file not found",
                    message: "No desktop OAuth client JSON exists at the supplied path.",
                    resolution: "Use the actual downloaded JSON file path. Do not type angle-bracket examples literally.",
                    retryable: false,
                    exitCode: 2
                )
            }
            return try resolver.importConfiguration(from: url)
        }
        if let configured = try resolver.configured() {
            return configured
        }

        // Migrate profiles created by the earlier `--client-secrets` login flow.
        // The configuration remains inside secure credentials throughout.
        if let existing = try OAuthProfileStore().activeProfile()?.1.configuration {
            try resolver.remember(existing)
            return existing
        }

        throw CLIError(
            code: "OAUTH_CLIENT_NOT_CONFIGURED",
            title: "Google sign-in is unavailable in this installation",
            message: "The installer did not provision GDA's desktop OAuth client, so no browser was opened and your Google account was not contacted.",
            resolution: "Install an OAuth-ready GDA build. End users should never need an OAuth JSON file; `gda auth onboard --api-key` remains available as an alternative.",
            retryable: false,
            suggestedCommand: "gda auth onboard --api-key",
            exitCode: 6
        )
    }
}

private func selectedOAuthProfile(account: String?) async throws -> OAuthProfile {
    try await CLIUtils.withCredentialPoolLock {
        let store = OAuthProfileStore()
        if let account { return try store.profile(id: account).0 }
        guard let active = try store.activeProfile()?.0 else { throw OAuthError.profileNotFound }
        return active
    }
}

private func updateOAuthModelPolicy(account: String?, policy: OAuthModelPolicy) async throws -> OAuthProfile {
    try await CLIUtils.withCredentialPoolLock {
        let store = OAuthProfileStore()
        let profileID: String
        if let account {
            profileID = try store.profile(id: account).0.id
        } else if let active = try store.activeProfile()?.0 {
            profileID = active.id
        } else {
            throw OAuthError.profileNotFound
        }
        return try store.updateModelPolicy(profileID: profileID, policy: policy)
    }
}

private func updateOAuthCreditPolicy(account: String?, policy: CreditPolicy) async throws -> OAuthProfile {
    try await CLIUtils.withCredentialPoolLock {
        let store = OAuthProfileStore()
        let profileID: String
        if let account {
            profileID = try store.profile(id: account).0.id
        } else if let active = try store.activeProfile()?.0 {
            profileID = active.id
        } else {
            throw OAuthError.profileNotFound
        }
        return try store.updateCreditPolicy(profileID: profileID, policy: policy)
    }
}

private func makeOAuthModelPolicy(preferred: String, fallbacks: [String]) throws -> OAuthModelPolicy {
    let candidates = [preferred] + fallbacks
    var seen = Set<String>()
    let normalized = candidates.compactMap { raw -> String? in
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.count <= 120,
              value.range(of: "^[A-Za-z0-9._:-]+$", options: .regularExpression) != nil,
              seen.insert(value).inserted else { return nil }
        return value
    }
    guard let first = normalized.first, first == preferred.trimmingCharacters(in: .whitespacesAndNewlines) else {
        throw CLIError("Preferred model must be a non-empty Gemini model identifier.")
    }
    guard normalized.count == candidates.count else {
        throw CLIError("Fallback models must be unique, valid identifiers and must not repeat the preferred model.")
    }
    return OAuthModelPolicy(preferred: first, fallbacks: Array(normalized.dropFirst()))
}
