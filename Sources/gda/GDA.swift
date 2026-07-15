import Foundation
import ArgumentParser
import GeminiDesignAgentCore
import GDAPlatformSupport

@main
struct GDA: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gda",
        abstract: "Gemini Design Agent - analyze UI screenshots with Gemini vision and layered design memory",
        version: GDAContract.productVersion,
        subcommands: [
            VersionCommand.self,
            SetupCommand.self,
            InitCommand.self,
            AnalyzeCommand.self,
            CompareCommand.self,
            DoctorCommand.self,
            LockCommand.self,
            AuthCommand.self,
            MemoryCommand.self,
            RunsCommand.self,
            ExportCommand.self,
            SnapshotCommand.self,
            CompactCommand.self,
            GCCommand.self,
            ResetCommand.self
        ]
    )
}

struct VersionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Show product and protocol contract versions"
    )

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() throws {
        if json {
            Logger.setJSONMode(true)
            try CLIResponse.successEncodable(command: "version", data: GDAContract.version)
        } else {
            print(GDAContract.productVersion)
        }
    }
}

enum CLIUtils {
    struct ResolvedGeminiAuthentication {
        let analyzer: any GeminiDesignAnalyzing
        let method: AuthenticationMode
        let profile: OAuthProfile?
        let quotaManager: AccountQuotaManager?
        let codeAssistRouter: CodeAssistFallbackAnalyzer?
    }

    static func loadAPIClient(
        apiKey: String? = nil,
        timeoutSeconds: Int = 120,
        apiKeyStore: APIKeyStore = KeychainAPIKeyStore()
    ) throws -> GeminiVisionClient {
        let key = try APIKeyResolver.resolve(apiKey: apiKey, store: apiKeyStore)
        return GeminiVisionClient(apiKey: key, timeoutSeconds: timeoutSeconds)
    }

    static func usesExplicitAPIKeyOverride(_ apiKey: String?) -> Bool {
        apiKey != nil || ProcessInfo.processInfo.environment["GEMINI_API_KEY"] != nil
    }

    static func resolveGeminiAuthentication(
        apiKey: String?,
        account: String?,
        timeoutSeconds: Int,
        modelFallbacks: [String]? = nil,
        creditConsentGranted: Bool = false
    ) async throws -> ResolvedGeminiAuthentication {
        guard apiKey == nil || account == nil else {
            throw CLIError(
                code: "AUTH_OVERRIDE_CONFLICT",
                title: "Authentication overrides conflict",
                message: "Pass either --api-key or --account, not both.",
                resolution: "Use --api-key for a one-run key override, or --account <profile-id> for a saved Google OAuth profile.",
                retryable: false,
                exitCode: 2
            )
        }

        if let apiKey {
            return ResolvedGeminiAuthentication(
                analyzer: try loadAPIClient(apiKey: apiKey, timeoutSeconds: timeoutSeconds),
                method: .apiKey,
                profile: nil,
                quotaManager: nil,
                codeAssistRouter: nil
            )
        }
        if let account {
            let profile = try OAuthProfileStore().profile(id: account).0
            return try await oauthAuthentication(
                profile: profile,
                pinned: true,
                timeoutSeconds: timeoutSeconds,
                modelFallbacks: modelFallbacks,
                creditConsentGranted: creditConsentGranted
            )
        }
        if let environmentKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"],
           !environmentKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ResolvedGeminiAuthentication(
                analyzer: GeminiVisionClient(apiKey: environmentKey, timeoutSeconds: timeoutSeconds),
                method: .apiKey,
                profile: nil,
                quotaManager: nil,
                codeAssistRouter: nil
            )
        }

        let persistent: (mode: AuthenticationMode?, profile: OAuthProfile?, key: String?) = try await withCredentialPoolLock { () throws -> (mode: AuthenticationMode?, profile: OAuthProfile?, key: String?) in
            let profileStore = OAuthProfileStore()
            let mode = try profileStore.loadMode()
            if let backend = mode?.backend {
                let active = try profileStore.activeProfile()?.0
                return (mode: mode, profile: active?.backend == backend ? active : nil, key: nil as String?)
            }
            if mode == .apiKey {
                let key = try APIKeyPoolCoordinator().selectPreferred()?.key
                return (mode: AuthenticationMode.apiKey, profile: nil as OAuthProfile?, key: key)
            }

            if let key = try APIKeyPoolCoordinator().selectPreferred() {
                return (mode: AuthenticationMode.apiKey, profile: nil as OAuthProfile?, key: key.key)
            }
            if let active = try profileStore.activeProfile()?.0 {
                return (mode: AuthenticationMode(backend: active.backend), profile: active, key: nil as String?)
            }
            return (mode: nil as AuthenticationMode?, profile: nil as OAuthProfile?, key: nil as String?)
        }

        if persistent.mode?.isOAuth == true, let profile = persistent.profile {
            return try await oauthAuthentication(
                profile: profile,
                pinned: false,
                timeoutSeconds: timeoutSeconds,
                modelFallbacks: modelFallbacks,
                creditConsentGranted: creditConsentGranted
            )
        }
        if persistent.mode == .apiKey, let key = persistent.key {
            return ResolvedGeminiAuthentication(
                analyzer: GeminiVisionClient(apiKey: key, timeoutSeconds: timeoutSeconds),
                method: .apiKey,
                profile: nil,
                quotaManager: nil,
                codeAssistRouter: nil
            )
        }
        if persistent.mode == .apiKey { throw GeminiError.apiKeyMissing }
        if persistent.mode?.isOAuth == true { throw OAuthError.profileNotFound }
        throw GeminiError.codeAssistAccountNeeded
    }

    private static func codeAssistAuthentication(
        profile: OAuthProfile,
        pinned: Bool,
        timeoutSeconds: Int,
        modelFallbacks: [String]?,
        creditConsentGranted: Bool
    ) async throws -> ResolvedGeminiAuthentication {
        let quotaManager = AccountQuotaManager()
        try await quotaManager.loadAccounts()
        _ = await quotaManager.switchToAccount(profileID: profile.id)

        if profile.companionProjectID != nil, !profile.hasOnboarded {
            _ = await quotaManager.setupAccount(
                profileID: profile.id,
                projectID: profile.effectiveProjectID,
                tierID: CodeAssist.UserTierID.standard.rawValue,
                tierName: nil,
                hasOnboarded: profile.hasOnboarded
            )
        }

        for account in await quotaManager.availableAccounts() where !account.projectID.isEmpty {
            _ = try? await quotaManager.refreshQuotaIfStale(profileID: account.profileID)
        }

        let fallbackAnalyzer = CodeAssistFallbackAnalyzer(
            quotaManager: quotaManager,
            profileStore: OAuthProfileStore(),
            timeoutSeconds: timeoutSeconds,
            pinnedProfileID: pinned ? profile.id : nil,
            modelFallbacks: modelFallbacks ?? profile.modelPolicy.fallbacks,
            creditConsentGranted: creditConsentGranted
        )

        return ResolvedGeminiAuthentication(
            analyzer: fallbackAnalyzer,
            method: .codeAssist,
            profile: profile,
            quotaManager: quotaManager,
            codeAssistRouter: fallbackAnalyzer
        )
    }

    private static func oauthAuthentication(
        profile: OAuthProfile,
        pinned: Bool,
        timeoutSeconds: Int,
        modelFallbacks: [String]?,
        creditConsentGranted: Bool
    ) async throws -> ResolvedGeminiAuthentication {
        switch profile.backend {
        case .codeAssist:
            return try await codeAssistAuthentication(
                profile: profile,
                pinned: pinned,
                timeoutSeconds: timeoutSeconds,
                modelFallbacks: modelFallbacks,
                creditConsentGranted: creditConsentGranted
            )
        case .publicGeminiAPI:
            let authorizer = OAuthTokenManager(profileID: profile.id)
            return ResolvedGeminiAuthentication(
                analyzer: GeminiVisionClient(authorizer: authorizer, timeoutSeconds: timeoutSeconds),
                method: .publicOAuth,
                profile: profile,
                quotaManager: nil,
                codeAssistRouter: nil
            )
        }
    }

    static func withCredentialPoolLock<T>(_ body: () async throws -> T) async throws -> T {
        let lockDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".geminidesignagent-credential-pool.lock", isDirectory: true)
        let lock = try await FileSystemLock.acquire(
            lockDirectory: lockDirectory,
            timeoutSeconds: 30,
            purpose: "credential-pool"
        )
        defer { lock.release() }
        return try await body()
    }

    static func nextPacificMidnight(after date: Date = Date()) -> Date {
        APIKeyPoolCoordinator.nextPacificMidnight(after: date)
    }

    static func loadOrInitProject(projectDir: String, projectName: String = "Design Project") throws -> (RuntimeContext, ArtifactPaths, SQLiteDB) {
        let dirURL = URL(fileURLWithPath: projectDir, isDirectory: true)
        let paths = ArtifactPaths(projectDir: dirURL)

        if !FileManager.default.fileExists(atPath: paths.configPath.path) {
            try paths.ensureDirectories()
            let db = try SQLiteDB(path: paths.dbPath.path)
            try DatabaseMigrator.migrate(db: db)

            let projectId = StableID.project()
            let configData = try JSONSerialization.data(withJSONObject: [
                "project_id": projectId,
                "project_name": projectName,
                "created_at": ISO8601DateFormatter().string(from: Date())
            ], options: .sortedKeys)
            try configData.write(to: paths.configPath)
            Logger.info("Auto-initialized project at \(projectDir)")
        }

        let configData = try Data(contentsOf: paths.configPath)
        guard let configJSON = try JSONSerialization.jsonObject(with: configData) as? [String: Any],
              let projectId = configJSON["project_id"] as? String else {
            throw CLIError("Invalid config.json in \(projectDir)")
        }

        let projectNameLoaded = configJSON["project_name"] as? String ?? projectName

        let context = RuntimeContext(
            projectId: projectId,
            projectName: projectNameLoaded,
            projectDir: projectDir
        )

        let db = try SQLiteDB(path: paths.dbPath.path)
        try DatabaseMigrator.migrate(db: db)

        return (context, paths, db)
    }

    static func printJSON(_ value: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]),
              let str = String(data: data, encoding: .utf8) else {
            print("{}")
            return
        }
        print(str)
    }

    static func shutdownHTTPClient() async {}
}

struct InitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Initialize a new design memory project",
        discussion: """
        Examples:
          gda init --project-dir .gda --project-name "iOS App"
          gda init --json
          gda doctor --project-dir .gda --json
        """
    )

    @Option(name: .long, help: "Project directory path")
    var projectDir: String = ".gda"

    @Option(name: .long, help: "Project name")
    var projectName: String = "Design Project"

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }

        let dirURL = URL(fileURLWithPath: projectDir, isDirectory: true)
        let paths = ArtifactPaths(projectDir: dirURL)

        try paths.ensureDirectories()

        let db = try SQLiteDB(path: paths.dbPath.path)
        try DatabaseMigrator.migrate(db: db)

        let projectId = StableID.project()

        let configData = try JSONSerialization.data(withJSONObject: [
            "project_id": projectId,
            "project_name": projectName,
            "created_at": ISO8601DateFormatter().string(from: Date())
        ], options: .sortedKeys)
        try configData.write(to: paths.configPath)

        if json {
            CLIResponse.success(
                command: "init",
                data: [
                    "project_id": projectId,
                    "project_dir": projectDir,
                    "database_path": paths.dbPath.path
                ],
                nextActions: [
                    ["label": "Check project health", "command": "gda doctor --project-dir \(projectDir) --json"],
                    ["label": "Analyze a screenshot", "command": "gda analyze --project-dir \(projectDir) --image screen.png --screen Home --json"]
                ]
            )
        } else {
            print("Project initialized: \(projectName)")
            print("  Project ID: \(projectId)")
            print("  Directory:  \(projectDir)")
        }
    }
}
