import Foundation
import GeminiDesignAgentCore

public actor CodeAssistFallbackAnalyzer: GeminiDesignAnalyzing {
    private let quotaManager: AccountQuotaManager
    private let profileStore: OAuthProfileStore
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date
    private let timeoutSeconds: Int
    private let pinnedProfileID: String?
    private let modelFallbacks: [String]
    private let usageLedger: OAuthUsageLedger
    private let creditConsentGranted: Bool
    private var attemptedProfileIDs: Set<String> = []
    private var attemptedModels: [String] = []
    private var stickyModel: String?
    private var stickyAccountID: String?

    private static let maxRetries = 5

    public init(
        quotaManager: AccountQuotaManager,
        profileStore: OAuthProfileStore = OAuthProfileStore(),
        transport: HTTPTransport = URLSessionHTTPTransport(),
        timeoutSeconds: Int = 120,
        pinnedProfileID: String? = nil,
        modelFallbacks: [String] = [],
        usageLedger: OAuthUsageLedger = OAuthUsageLedger(),
        creditConsentGranted: Bool = false
    ) {
        self.quotaManager = quotaManager
        self.profileStore = profileStore
        self.transport = transport
        self.now = Date.init
        self.timeoutSeconds = timeoutSeconds
        self.pinnedProfileID = pinnedProfileID
        self.modelFallbacks = Self.normalized(modelFallbacks)
        self.usageLedger = usageLedger
        self.creditConsentGranted = creditConsentGranted
    }

    public func attemptedProfileIDsSnapshot() -> Set<String> { attemptedProfileIDs }
    public func attemptedModelsSnapshot() -> [String] { Self.normalized(attemptedModels) }

    public func resetRoutingObservations() {
        attemptedProfileIDs = []
        attemptedModels = []
    }

    public func analyzeImage(
        model: String,
        imageURL: URL,
        mimeType: String,
        systemInstruction: String,
        userPrompt: String,
        responseSchema: JSONValue
    ) async throws -> GeminiRawTextResponse {
        return try await route(preferredModel: model) { profileID, candidate in
            var response = try await self.analyzeWithAccount(
                profileID: profileID,
                model: candidate,
                imageURL: imageURL,
                mimeType: mimeType,
                systemInstruction: systemInstruction,
                userPrompt: userPrompt,
                responseSchema: responseSchema
            )
            response.model = candidate
            return response
        }
    }

    public func analyzeText(
        model: String,
        systemInstruction: String,
        userPrompt: String,
        responseSchema: JSONValue
    ) async throws -> GeminiRawTextResponse {
        return try await route(preferredModel: model) { profileID, candidate in
            var response = try await self.analyzeWithAccount(
                profileID: profileID,
                model: candidate,
                imageURL: nil,
                mimeType: "",
                systemInstruction: systemInstruction,
                userPrompt: userPrompt,
                responseSchema: responseSchema
            )
            response.model = candidate
            return response
        }
    }

    private func route(
        preferredModel: String,
        operation: @escaping @Sendable (String, String) async throws -> GeminiRawTextResponse
    ) async throws -> GeminiRawTextResponse {
        let candidates = Self.normalized([stickyModel ?? preferredModel] + modelFallbacks)
        var exhaustedProfileIDs = Set<String>()
        var lastError: Error?

        var modelIndex = 0
        while modelIndex < candidates.count {
            let modelCandidate = candidates[modelIndex]
            var triedProfileIDs = Set<String>()
            var retryAttempts = 0
            var retryProfileID: String?

            accountLoop: while true {
                let resolvedProfileID: String
                if let retry = retryProfileID {
                    resolvedProfileID = retry
                    retryProfileID = nil
                } else if let pinned = pinnedProfileID {
                    resolvedProfileID = pinned
                } else if let sticky = stickyAccountID,
                          !exhaustedProfileIDs.contains(sticky),
                          !triedProfileIDs.contains(sticky) {
                    resolvedProfileID = sticky
                } else {
                    guard let nextID = await quotaManager.nextAvailableAccount(
                        for: modelCandidate,
                        excluding: exhaustedProfileIDs.union(triedProfileIDs)
                    ) else {
                        break accountLoop
                    }
                    resolvedProfileID = nextID
                }

                triedProfileIDs.insert(resolvedProfileID)
                attemptedProfileIDs.insert(resolvedProfileID)
                attemptedModels.append(modelCandidate)
                try? await usageLedger.recordAttempt(profileID: resolvedProfileID, model: modelCandidate)

                do {
                    var response = try await operation(resolvedProfileID, modelCandidate)
                    response.profileID = resolvedProfileID
                    try? await usageLedger.recordSuccess(
                        profileID: resolvedProfileID,
                        model: response.model,
                        usage: response.usage.map(RunTokenUsage.init)
                    )
                    if let balance = response.googleOneAICreditBalance {
                        _ = try? profileStore.updateGoogleOneAICreditBalance(profileID: resolvedProfileID, balance: balance)
                    }
                    stickyModel = modelCandidate
                    stickyAccountID = resolvedProfileID
                    return response
                } catch let error as GeminiError {
                    try? await usageLedger.recordFailure(
                        profileID: resolvedProfileID,
                        model: modelCandidate,
                        errorCode: Self.usageErrorCode(error),
                        cooldownUntil: Self.cooldownUntil(for: error, now: now())
                    )
                    switch error {
                    case .modelQuotaExhausted:
                        await quotaManager.markQuotaExhausted(profileID: resolvedProfileID, model: modelCandidate, error: error)
                        lastError = error
                        if pinnedProfileID != nil { break accountLoop }
                        retryAttempts = 0
                        continue accountLoop
                    case .modelNotFound:
                        lastError = error
                        if pinnedProfileID != nil { break accountLoop }
                        retryAttempts = 0
                        continue accountLoop
                    case .quotaExhausted:
                        await quotaManager.markQuotaExhausted(profileID: resolvedProfileID, model: modelCandidate, error: error)
                        exhaustedProfileIDs.insert(resolvedProfileID)
                        if resolvedProfileID == stickyAccountID { stickyAccountID = nil }
                        lastError = error
                        if pinnedProfileID != nil {
                            throw error
                        }
                        retryAttempts = 0
                        continue accountLoop
                    case .rateLimited, .timeout, .connectionFailed, .networkUnavailable, .dnsFailure:
                        lastError = error
                        retryAttempts += 1
                        if retryAttempts > Self.maxRetries {
                            throw error
                        }
                        retryProfileID = resolvedProfileID
                        continue accountLoop
                    default:
                        throw error
                    }
                }
            }

            modelIndex += 1
        }

        throw lastError ?? GeminiError.codeAssistAccountNeeded
    }

    private func analyzeWithAccount(
        profileID: String,
        model: String,
        imageURL: URL?,
        mimeType: String,
        systemInstruction: String,
        userPrompt: String,
        responseSchema: JSONValue
    ) async throws -> GeminiRawTextResponse {
        guard let secret = try profileStore.loadSecret(profileID: profileID) else {
            throw OAuthError.profileNotFound
        }
        let profile = try profileStore.profile(id: profileID).0

        let account = await quotaManager.availableAccounts().first { $0.profileID == profileID }
        let projectID = account?.projectID ?? secret.configuration.projectID

        let authorizer = OAuthTokenManager(
            profileID: profileID,
            store: profileStore,
            transport: transport,
            now: now
        )

        let codeAssistClient = CodeAssistClient(
            authorizer: authorizer,
            projectID: projectID,
            transport: transport,
            timeoutSeconds: timeoutSeconds
        )

        let enabledCreditTypes = CodeAssistCreditPolicy.enabledCreditTypes(
            policy: profile.creditPolicy,
            model: model,
            balance: profile.googleOneAICreditBalance,
            consentGranted: creditConsentGranted
        )
        let visionClient = CodeAssistVisionClient(client: codeAssistClient, enabledCreditTypes: enabledCreditTypes)

        if let imageURL {
            return try await visionClient.analyzeImage(
                model: model,
                imageURL: imageURL,
                mimeType: mimeType,
                systemInstruction: systemInstruction,
                userPrompt: userPrompt,
                responseSchema: responseSchema
            )
        } else {
            return try await visionClient.analyzeText(
                model: model,
                systemInstruction: systemInstruction,
                userPrompt: userPrompt,
                responseSchema: responseSchema
            )
        }
    }

    private static func normalized(_ models: [String]) -> [String] {
        var seen = Set<String>()
        return models.compactMap { value in
            let model = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty, seen.insert(model).inserted else { return nil }
            return model
        }
    }

    private static func usageErrorCode(_ error: GeminiError) -> String {
        switch error {
        case .rateLimited: return "rate_limited"
        case .quotaExhausted: return "project_quota_exhausted"
        case .modelQuotaExhausted: return "model_quota_exhausted"
        case .insufficientCredits: return "insufficient_credits"
        case .modelNotFound: return "model_not_found"
        case .billingDisabled: return "billing_disabled"
        case .invalidAPIKey: return "authentication_failed"
        case .contentBlocked: return "content_blocked"
        default: return "gemini_request_failed"
        }
    }

    private static func cooldownUntil(for error: GeminiError, now: Date) -> Date? {
        guard case let .rateLimited(retryAfterSeconds) = error,
              let retryAfterSeconds,
              retryAfterSeconds > 0 else {
            return nil
        }
        return now.addingTimeInterval(TimeInterval(retryAfterSeconds))
    }
}
