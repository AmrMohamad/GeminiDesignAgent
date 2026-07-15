import Foundation
import GeminiDesignAgentCore

public actor AccountQuotaManager {
    private var accounts: [CodeAssist.AccountQuota] = []
    private let profileStore: OAuthProfileStore
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date
    private var activeAccountIndex: Int?
    private var cooldownExpirations: [String: Date] = [:]

    public init(
        profileStore: OAuthProfileStore = OAuthProfileStore(),
        transport: HTTPTransport = URLSessionHTTPTransport()
    ) {
        self.profileStore = profileStore
        self.transport = transport
        self.now = Date.init
    }

    public func availableAccounts() -> [CodeAssist.AccountQuota] {
        accounts
    }

    public func activeAccount() -> CodeAssist.AccountQuota? {
        guard let index = activeAccountIndex, accounts.indices.contains(index) else { return nil }
        return accounts[index]
    }

    public func loadAccounts() async throws {
        let profiles = try profileStore.profileSummaries()
        let usableProfiles = profiles.filter {
            $0.backend == .codeAssist && ($0.tokenState == "valid" || $0.tokenState == "refresh-needed")
        }
        accounts = usableProfiles.map { summary in
            if let existing = accounts.first(where: { $0.profileID == summary.id }) {
                return existing
            }
            return CodeAssist.AccountQuota(
                profileID: summary.id,
                email: summary.maskedEmail,
                projectID: summary.companionProjectID ?? "",
                dailyQuotaExhausted: false
            )
        }

        if !accounts.isEmpty {
            let activeID = (try? profileStore.activeProfile()?.0.id) ?? profiles.first(where: { $0.isActive })?.id
            if let activeID {
                activeAccountIndex = accounts.firstIndex(where: { $0.profileID == activeID }) ?? 0
            } else {
                activeAccountIndex = 0
            }
        }
    }

    @discardableResult
    public func setupAccount(profileID: String, projectID: String, tierID: String, tierName: String?, hasOnboarded: Bool) -> CodeAssist.AccountQuota? {
        guard let index = accounts.firstIndex(where: { $0.profileID == profileID }) else { return nil }
        var updated = accounts[index]
        updated.projectID = projectID
        updated.tierID = tierID
        updated.tierName = tierName
        updated.hasOnboarded = hasOnboarded
        accounts[index] = updated
        return updated
    }

    public func refreshQuota(profileID: String) async throws -> [String: [CodeAssist.ModelQuota]] {
        guard let account = accounts.first(where: { $0.profileID == profileID }),
              !account.projectID.isEmpty else { return [:] }

        guard try profileStore.loadSecret(profileID: profileID) != nil else {
            throw OAuthError.profileNotFound
        }

        let authorizer = OAuthTokenManager(
            profileID: profileID,
            store: profileStore,
            transport: transport,
            now: now
        )

        let client = CodeAssistClient(
            authorizer: authorizer,
            projectID: account.projectID,
            transport: transport
        )

        let quotaResponse = try await client.retrieveUserQuota(project: account.projectID)
        let experiments = try? await client.listExperiments(project: account.projectID)
        guard let buckets = quotaResponse.buckets else {
            return account.modelQuotas
        }
        var modelQuotas: [String: [CodeAssist.ModelQuota]] = [:]

        for bucket in buckets {
            guard let modelID = bucket.modelId else { continue }
            let resetTime = bucket.resetTime.flatMap { ISO8601DateFormatter().date(from: $0) }
            let quota = CodeAssist.ModelQuota(
                remainingAmount: bucket.remainingAmount,
                remainingFraction: bucket.remainingFraction,
                resetTime: resetTime,
                tokenType: bucket.tokenType
            )
            modelQuotas[modelID, default: []].append(quota)
        }

        if let index = accounts.firstIndex(where: { $0.profileID == profileID }) {
            accounts[index].modelQuotas = modelQuotas
            if let flags = experiments?.flags {
                accounts[index].experimentFlags = flags.reduce(into: [:]) { values, flag in
                    if let id = flag.flagId, let value = flag.boolValue { values[id] = value }
                }
            }
            accounts[index].lastQuotaRefresh = now()
        }

        return modelQuotas
    }

    public func refreshQuotaIfStale(
        profileID: String,
        maximumAge: TimeInterval = 30
    ) async throws -> [String: [CodeAssist.ModelQuota]] {
        guard let account = accounts.first(where: { $0.profileID == profileID }) else {
            throw OAuthError.profileNotFound
        }
        let hasExpiredBucket = account.modelQuotas.values
            .joined()
            .contains { quota in quota.isExhausted && quota.resetTime.map { $0 <= now() } == true }
        if !hasExpiredBucket,
           let refreshed = account.lastQuotaRefresh,
           now().timeIntervalSince(refreshed) >= 0,
           now().timeIntervalSince(refreshed) < maximumAge {
            return account.modelQuotas
        }
        return try await refreshQuota(profileID: profileID)
    }

    public func markQuotaExhausted(profileID: String, model: String, error: GeminiError) {
        guard let index = accounts.firstIndex(where: { $0.profileID == profileID }) else { return }
        switch error {
        case .quotaExhausted:
            accounts[index].dailyQuotaExhausted = true
        case .modelQuotaExhausted:
            accounts[index].modelQuotas[model] = [CodeAssist.ModelQuota(
                remainingAmount: "0",
                remainingFraction: 0,
                resetTime: nil,
                tokenType: nil
            )]
        default:
            break
        }
    }

    public func markCooldown(profileID: String, until: Date) {
        cooldownExpirations[profileID] = until
    }

    public func resetCooldown(profileID: String?) {
        if let profileID {
            cooldownExpirations.removeValue(forKey: profileID)
            if let index = accounts.firstIndex(where: { $0.profileID == profileID }) {
                accounts[index].dailyQuotaExhausted = false
                accounts[index].lastQuotaRefresh = nil
            }
        } else {
            cooldownExpirations.removeAll()
            for index in accounts.indices {
                accounts[index].dailyQuotaExhausted = false
                accounts[index].lastQuotaRefresh = nil
            }
        }
    }

    public func nextAvailableAccount(
        for model: String,
        excluding excludedProfileIDs: Set<String> = []
    ) -> String? {
        let exhausted = exhaustedProfileIDs(for: model).union(excludedProfileIDs)

        if let activeID = activeAccount()?.profileID, !exhausted.contains(activeID) {
            return activeID
        }

        for account in accounts {
            if account.profileID == activeAccount()?.profileID { continue }
            if excludedProfileIDs.contains(account.profileID) { continue }
            if account.dailyQuotaExhausted { continue }
            if !modelIsEntitled(model, for: account) { continue }
            if account.modelQuotas[model]?.contains(where: { $0.isExhausted(at: now()) }) == true { continue }
            if let cooldown = cooldownExpirations[account.profileID], cooldown > now() { continue }
            if !account.projectID.isEmpty {
                return account.profileID
            }
        }

        return nil
    }

    public func nextAvailableModel(
        for profileID: String,
        preferred: String,
        fallbacks: [String]
    ) -> String? {
        let candidates = [preferred] + fallbacks
        guard let index = accounts.firstIndex(where: { $0.profileID == profileID }) else { return nil }
        let account = accounts[index]

        for candidate in candidates {
            if account.dailyQuotaExhausted { return nil }
            if !modelIsEntitled(candidate, for: account) { continue }
            if account.modelQuotas[candidate]?.contains(where: { $0.isExhausted(at: now()) }) == true { continue }
            return candidate
        }
        return nil
    }

    public func exhaustedProfileIDs(for model: String) -> Set<String> {
        var exhausted: Set<String> = []
        for account in accounts {
            if account.dailyQuotaExhausted {
                exhausted.insert(account.profileID)
                continue
            }
            if account.modelQuotas[model]?.contains(where: { $0.isExhausted(at: now()) }) == true {
                exhausted.insert(account.profileID)
                continue
            }
            if let cooldown = cooldownExpirations[account.profileID], cooldown > now() {
                exhausted.insert(account.profileID)
                continue
            }
        }
        return exhausted
    }

    public func switchToAccount(profileID: String) -> Bool {
        guard let index = accounts.firstIndex(where: { $0.profileID == profileID }),
              !accounts[index].projectID.isEmpty else { return false }
        activeAccountIndex = index
        _ = try? profileStore.select(profileID: profileID)
        return true
    }

    private func modelIsEntitled(_ model: String, for account: CodeAssist.AccountQuota) -> Bool {
        if model.contains("pro"), account.experimentFlags[CodeAssist.ExperimentFlagID.proModelNoAccess] == true {
            return false
        }
        if model.hasPrefix("gemini-3.1-pro"),
           account.experimentFlags[CodeAssist.ExperimentFlagID.gemini31ProLaunched] == false {
            return false
        }
        return true
    }
}
