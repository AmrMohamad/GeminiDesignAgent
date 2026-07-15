import Foundation

public struct CodeAssistUserData: Sendable {
    public var profileID: String
    public var projectID: String
    public var userTier: String
    public var tierName: String?
    public var hasOnboardedPreviously: Bool
    public var paidTierName: String?
    public var availableCredits: [CodeAssist.Credits]?
    public var ineligibleReason: String?
    public var requiresValidation: Bool
    public var validationURL: String?
    public var validationMessage: String?

    public init(
        profileID: String,
        projectID: String,
        userTier: String,
        tierName: String? = nil,
        hasOnboardedPreviously: Bool = false,
        paidTierName: String? = nil,
        availableCredits: [CodeAssist.Credits]? = nil,
        ineligibleReason: String? = nil,
        requiresValidation: Bool = false,
        validationURL: String? = nil,
        validationMessage: String? = nil
    ) {
        self.profileID = profileID
        self.projectID = projectID
        self.userTier = userTier
        self.tierName = tierName
        self.hasOnboardedPreviously = hasOnboardedPreviously
        self.paidTierName = paidTierName
        self.availableCredits = availableCredits
        self.ineligibleReason = ineligibleReason
        self.requiresValidation = requiresValidation
        self.validationURL = validationURL
        self.validationMessage = validationMessage
    }
}

public struct CodeAssistSetup: Sendable {
    private let client: CodeAssistClient

    public init(client: CodeAssistClient) {
        self.client = client
    }

    public func setupUser(
        profileID: String,
        cloudaicompanionProject: String? = nil
    ) async throws -> CodeAssistUserData {
        let environmentProject = resolveEnvironmentProject()
        let companionProject = cloudaicompanionProject ?? environmentProject

        let loadRes = try await client.loadCodeAssist(
            cloudaicompanionProject: companionProject
        )

        if let currentTier = loadRes.currentTier {
            let projectID = loadRes.cloudaicompanionProject ?? companionProject ?? ""
            if projectID.isEmpty {
                throw GeminiError.codeAssistSetupFailed("No project ID returned from Code Assist; set GOOGLE_CLOUD_PROJECT or try a different account")
            }
            let tierID = loadRes.paidTier?.id ?? currentTier.id ?? CodeAssist.UserTierID.standard.rawValue
            let tierName = loadRes.paidTier?.name ?? currentTier.name

            return CodeAssistUserData(
                profileID: profileID,
                projectID: projectID,
                userTier: tierID,
                tierName: tierName,
                hasOnboardedPreviously: currentTier.hasOnboardedPreviously ?? true,
                paidTierName: loadRes.paidTier?.name,
                availableCredits: loadRes.paidTier?.availableCredits
            )
        }

        if let ineligible = loadRes.ineligibleTiers, !ineligible.isEmpty {
            if let validationTier = ineligible.first(where: { $0.reasonCode == "VALIDATION_REQUIRED" }) {
                let message = validationTier.validationErrorMessage
                    ?? validationTier.reasonMessage
                    ?? "Google account validation is required before Code Assist can be used"
                throw GeminiError.codeAssistSetupFailed(message)
            }
            let reasons = ineligible.compactMap { $0.reasonMessage }.joined(separator: ", ")
            throw GeminiError.codeAssistSetupFailed(reasons.isEmpty ? "Account is not eligible for any Code Assist tier" : reasons)
        }

        let tier = selectOnboardTier(from: loadRes)
        let tierID = tier.id ?? CodeAssist.UserTierID.standard.rawValue

        let onboardProject: String?
        if tierID == CodeAssist.UserTierID.free.rawValue {
            onboardProject = nil
        } else {
            onboardProject = loadRes.cloudaicompanionProject ?? companionProject
        }

        var lroRes = try await client.onboardUser(
            tierID: tierID,
            cloudaicompanionProject: onboardProject
        )

        if !(lroRes.done ?? false), let name = lroRes.name {
            let pollDeadline = Date().addingTimeInterval(300)
            while !(lroRes.done ?? false) {
                if Date() > pollDeadline {
                    throw GeminiError.codeAssistSetupFailed("Onboarding operation timed out after 5 minutes")
                }
                try await Task.sleep(for: .seconds(5))
                lroRes = try await client.getOperation(name: name)
            }
        }

        let projectID = lroRes.response?.cloudaicompanionProject?.id
            ?? loadRes.cloudaicompanionProject
            ?? companionProject
            ?? ""
        if projectID.isEmpty {
            throw GeminiError.codeAssistSetupFailed("Onboarding completed but no project ID was returned; set GOOGLE_CLOUD_PROJECT and try again")
        }

        return CodeAssistUserData(
            profileID: profileID,
            projectID: projectID,
            userTier: tierID,
            tierName: tier.name,
            hasOnboardedPreviously: tier.hasOnboardedPreviously ?? false
        )
    }

    private func resolveEnvironmentProject() -> String? {
        let project = ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT"]
            ?? ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT_ID"]
        guard let project, !project.isEmpty else { return nil }
        if project.allSatisfy(\.isNumber) { return nil }
        return project
    }

    private func selectOnboardTier(from response: CodeAssist.LoadCodeAssistResponse) -> CodeAssist.GeminiUserTier {
        for tier in response.allowedTiers ?? [] where tier.isDefault == true {
            return tier
        }
        return CodeAssist.GeminiUserTier(
            id: CodeAssist.UserTierID.legacy.rawValue,
            name: "",
            userDefinedCloudaicompanionProject: true
        )
    }
}
