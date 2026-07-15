import Foundation

public enum CodeAssist {
    public static let baseURL = URL(string: "https://cloudcode-pa.googleapis.com")!
    public static let apiVersion = "v1internal"

    public enum UserTierID: String, Codable, Sendable, CaseIterable {
        case free = "free-tier"
        case legacy = "legacy-tier"
        case standard = "standard-tier"
    }

    public enum CreditType: String, Codable, Sendable {
        case unspecified = "CREDIT_TYPE_UNSPECIFIED"
        case googleOneAI = "GOOGLE_ONE_AI"
    }

    public struct Credits: Codable, Equatable, Sendable {
        public var creditType: String
        public var creditAmount: String

        public init(creditType: String, creditAmount: String) {
            self.creditType = creditType
            self.creditAmount = creditAmount
        }
    }

    public struct ClientMetadata: Codable, Sendable {
        public var ideType: String
        public var platform: String
        public var pluginType: String
        public var duetProject: String?
        public var ideVersion: String?
        public var updateChannel: String?

        public init(
            ideType: String = "IDE_UNSPECIFIED",
            platform: String = CodeAssist.ClientMetadata.currentPlatform,
            pluginType: String = "GEMINI",
            duetProject: String? = nil,
            ideVersion: String? = nil,
            updateChannel: String? = nil
        ) {
            self.ideType = ideType
            self.platform = platform
            self.pluginType = pluginType
            self.duetProject = duetProject
            self.ideVersion = ideVersion
            self.updateChannel = updateChannel
        }

        public static var currentPlatform: String {
            #if arch(arm64)
            let arch = "ARM64"
            #else
            let arch = "AMD64"
            #endif
            #if os(macOS)
            return "DARWIN_\(arch)"
            #elseif os(Linux)
            return "LINUX_\(arch)"
            #elseif os(Windows)
            return "WINDOWS_\(arch)"
            #else
            return "PLATFORM_UNSPECIFIED"
            #endif
        }
    }

    public struct GeminiUserTier: Codable, Equatable, Sendable {
        public var id: String?
        public var name: String?
        public var description: String?
        public var userDefinedCloudaicompanionProject: Bool?
        public var isDefault: Bool?
        public var hasAcceptedTos: Bool?
        public var hasOnboardedPreviously: Bool?
        public var availableCredits: [Credits]?
    }

    public struct IneligibleTier: Codable, Sendable {
        public var reasonCode: String?
        public var reasonMessage: String?
        public var tierId: String?
        public var tierName: String?
        public var validationErrorMessage: String?
        public var validationUrl: String?
        public var validationUrlLinkText: String?
        public var validationLearnMoreUrl: String?
        public var validationLearnMoreLinkText: String?

        enum CodingKeys: String, CodingKey {
            case reasonCode, reasonMessage, tierId, tierName
            case validationErrorMessage, validationUrl, validationUrlLinkText
            case validationLearnMoreUrl, validationLearnMoreLinkText
        }
    }

    public struct LoadCodeAssistRequest: Codable, Sendable {
        public var cloudaicompanionProject: String?
        public var metadata: ClientMetadata
        public var mode: String?

        public init(
            cloudaicompanionProject: String? = nil,
            metadata: ClientMetadata = ClientMetadata(),
            mode: String? = nil
        ) {
            self.cloudaicompanionProject = cloudaicompanionProject
            self.metadata = metadata
            self.mode = mode
        }
    }

    public struct LoadCodeAssistResponse: Codable, Sendable {
        public var currentTier: GeminiUserTier?
        public var allowedTiers: [GeminiUserTier]?
        public var ineligibleTiers: [IneligibleTier]?
        public var cloudaicompanionProject: String?
        public var paidTier: GeminiUserTier?

        enum CodingKeys: String, CodingKey {
            case currentTier, allowedTiers, ineligibleTiers, cloudaicompanionProject, paidTier
        }
    }

    public struct OnboardUserRequest: Codable, Sendable {
        public var tierId: String?
        public var cloudaicompanionProject: String?
        public var metadata: ClientMetadata?

        public init(
            tierId: String?,
            cloudaicompanionProject: String?,
            metadata: ClientMetadata? = ClientMetadata()
        ) {
            self.tierId = tierId
            self.cloudaicompanionProject = cloudaicompanionProject
            self.metadata = metadata
        }
    }

    public struct LongRunningOperationResponse: Codable, Sendable {
        public var name: String?
        public var done: Bool?
        public var response: OnboardUserResponse?
    }

    public struct OnboardUserResponse: Codable, Sendable {
        public var cloudaicompanionProject: CloudAICompanionProject?

        public struct CloudAICompanionProject: Codable, Sendable {
            public var id: String?
            public var name: String?
        }
    }

    public struct RetrieveUserQuotaRequest: Codable, Sendable {
        public var project: String
        public var userAgent: String?

        public init(project: String, userAgent: String? = nil) {
            self.project = project
            self.userAgent = userAgent
        }
    }

    public struct BucketInfo: Codable, Sendable {
        public var remainingAmount: String?
        public var remainingFraction: Double?
        public var resetTime: String?
        public var tokenType: String?
        public var modelId: String?
    }

    public struct RetrieveUserQuotaResponse: Codable, Sendable {
        public var buckets: [BucketInfo]?
    }

    public struct ListExperimentsRequest: Codable, Sendable {
        public var project: String
        public var metadata: ClientMetadata?

        public init(project: String, metadata: ClientMetadata? = nil) {
            self.project = project
            self.metadata = metadata
        }
    }

    public struct ListExperimentsResponse: Codable, Sendable {
        public var experimentIds: [Int]?
        public var flags: [ExperimentFlag]?
        public var filteredFlags: [FilteredExperimentFlag]?
        public var debugString: String?
    }

    public struct ExperimentFlag: Codable, Sendable {
        public var flagId: Int?
        public var boolValue: Bool?
        public var floatValue: Double?
        public var intValue: String?
        public var stringValue: String?
    }

    public struct FilteredExperimentFlag: Codable, Sendable {
        public var name: String?
        public var reason: String?
    }

    public enum ExperimentFlagID {
        public static let gemini31ProLaunched = 45_760_185
        public static let proModelNoAccess = 45_768_879
        public static let gemini35FlashGALaunched = 45_780_819
    }

    public struct GenerateContentRequest: Codable, Sendable {
        public var model: String
        public var project: String?
        public var userPromptId: String?
        public var enabledCreditTypes: [String]?
        public var request: VertexGenerateContentRequest

        enum CodingKeys: String, CodingKey {
            case model, project
            case userPromptId = "user_prompt_id"
            case enabledCreditTypes = "enabled_credit_types"
            case request
        }

        public init(
            model: String,
            project: String?,
            request: VertexGenerateContentRequest,
            userPromptId: String? = nil,
            enabledCreditTypes: [String]? = nil
        ) {
            self.model = model
            self.project = project
            self.request = request
            self.userPromptId = userPromptId
            self.enabledCreditTypes = enabledCreditTypes
        }
    }

    public struct VertexGenerateContentRequest: Codable, Sendable {
        public var contents: [GeminiContent]
        public var systemInstruction: GeminiContent?
        public var cachedContent: String?
        public var labels: [String: String]?
        public var generationConfig: VertexGenerationConfig?
        public var sessionId: String?
        public var safetySettings: [SafetySetting]?

        enum CodingKeys: String, CodingKey {
            case contents, labels, safetySettings
            case systemInstruction = "systemInstruction"
            case cachedContent = "cachedContent"
            case generationConfig = "generationConfig"
            case sessionId = "session_id"
        }

        public init(
            contents: [GeminiContent],
            systemInstruction: GeminiContent? = nil,
            generationConfig: VertexGenerationConfig? = nil
        ) {
            self.contents = contents
            self.systemInstruction = systemInstruction
            self.generationConfig = generationConfig
        }
    }

    public struct SafetySetting: Codable, Sendable {
        public var category: String
        public var threshold: String

        public init(category: String, threshold: String) {
            self.category = category
            self.threshold = threshold
        }
    }

    public struct GeminiContent: Codable, Sendable {
        public var role: String?
        public var parts: [GeminiPart]

        public init(role: String? = "user", parts: [GeminiPart]) {
            self.role = role
            self.parts = parts
        }
    }

    public enum GeminiPart: Codable, Sendable {
        case text(String)
        case inlineData(mimeType: String, data: String)

        enum CodingKeys: String, CodingKey {
            case text
            case inlineData
            case mimeType
            case data
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let text = try container.decodeIfPresent(String.self, forKey: .text) {
                self = .text(text)
            } else {
                let inlineDataContainer = try container.nestedContainer(keyedBy: CodingKeys.self, forKey: .inlineData)
                let mimeType = try inlineDataContainer.decode(String.self, forKey: .mimeType)
                let data = try inlineDataContainer.decode(String.self, forKey: .data)
                self = .inlineData(mimeType: mimeType, data: data)
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let value):
                try container.encode(value, forKey: .text)
            case .inlineData(let mimeType, let data):
                var nested = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .inlineData)
                try nested.encode(mimeType, forKey: .mimeType)
                try nested.encode(data, forKey: .data)
            }
        }
    }

    public struct VertexGenerationConfig: Codable, Sendable {
        public var temperature: Double?
        public var topP: Double?
        public var topK: Int?
        public var candidateCount: Int?
        public var maxOutputTokens: Int?
        public var stopSequences: [String]?
        public var responseMimeType: String?
        public var responseJsonSchema: JSONValue?
        public var responseSchema: JSONValue?
        public var thinkingConfig: ThinkingConfig?

        enum CodingKeys: String, CodingKey {
            case temperature
            case topP = "topP"
            case topK = "topK"
            case candidateCount = "candidateCount"
            case maxOutputTokens = "maxOutputTokens"
            case stopSequences = "stopSequences"
            case responseMimeType = "responseMimeType"
            case responseJsonSchema = "responseJsonSchema"
            case responseSchema = "responseSchema"
            case thinkingConfig = "thinkingConfig"
        }

        public init(
            temperature: Double? = nil,
            topP: Double? = nil,
            topK: Int? = nil,
            candidateCount: Int? = nil,
            maxOutputTokens: Int? = nil,
            stopSequences: [String]? = nil,
            responseMimeType: String? = nil,
            responseJsonSchema: JSONValue? = nil,
            responseSchema: JSONValue? = nil,
            thinkingConfig: ThinkingConfig? = nil
        ) {
            self.temperature = temperature
            self.topP = topP
            self.topK = topK
            self.candidateCount = candidateCount
            self.maxOutputTokens = maxOutputTokens
            self.stopSequences = stopSequences
            self.responseMimeType = responseMimeType
            self.responseJsonSchema = responseJsonSchema
            self.responseSchema = responseSchema
            self.thinkingConfig = thinkingConfig
        }
    }

    public struct ThinkingConfig: Codable, Sendable {
        public var includeThoughts: Bool?
        public var thinkingBudget: Int?

        enum CodingKeys: String, CodingKey {
            case includeThoughts = "includeThoughts"
            case thinkingBudget = "thinkingBudget"
        }

        public init(includeThoughts: Bool? = nil, thinkingBudget: Int? = nil) {
            self.includeThoughts = includeThoughts
            self.thinkingBudget = thinkingBudget
        }
    }

    public struct GenerateContentResponse: Codable, Sendable {
        public var response: VertexGenerateContentResponse?
        public var traceId: String?
        public var consumedCredits: [Credits]?
        public var remainingCredits: [Credits]?

        enum CodingKeys: String, CodingKey {
            case response, traceId, consumedCredits, remainingCredits
        }
    }

    public struct VertexGenerateContentResponse: Codable, Sendable {
        public var candidates: [Candidate]?
        public var promptFeedback: PromptFeedback?
        public var usageMetadata: UsageMetadata?
        public var modelVersion: String?

        enum CodingKeys: String, CodingKey {
            case candidates, promptFeedback, usageMetadata, modelVersion
        }
    }

    public struct Candidate: Codable, Sendable {
        public var content: GeminiContent?
        public var finishReason: String?
        public var safetyRatings: [SafetyRating]?
        public var index: Int?

        enum CodingKeys: String, CodingKey {
            case content, finishReason, safetyRatings, index
        }
    }

    public struct SafetyRating: Codable, Sendable {
        public var category: String?
        public var probability: String?
    }

    public struct PromptFeedback: Codable, Sendable {
        public var blockReason: String?
        public var safetyRatings: [SafetyRating]?
    }

    public struct UsageMetadata: Codable, Sendable {
        public var promptTokenCount: Int?
        public var candidatesTokenCount: Int?
        public var totalTokenCount: Int?
        public var thoughtsTokenCount: Int?
        public var cachedContentTokenCount: Int?
        public var promptTokensDetails: [ModalityTokenCount]?
        public var candidatesTokensDetails: [ModalityTokenCount]?

        enum CodingKeys: String, CodingKey {
            case promptTokenCount, candidatesTokenCount, totalTokenCount
            case thoughtsTokenCount, cachedContentTokenCount
            case promptTokensDetails, candidatesTokensDetails
        }
    }

    public struct ModalityTokenCount: Codable, Sendable {
        public var modality: String?
        public var tokenCount: Int?

        enum CodingKeys: String, CodingKey {
            case modality, tokenCount
        }
    }

    public struct CodeAssistErrorPayload: Decodable, Sendable {
        public var code: Int?
        public var message: String?
        public var status: String?
        public var details: [CodeAssistErrorDetail]?
    }

    public struct CodeAssistErrorDetail: Decodable, Sendable {
        public var type: String?
        public var reason: String?
        public var domain: String?
        public var metadata: [String: String]?

        enum CodingKeys: String, CodingKey {
            case type = "@type"
            case reason, domain, metadata
        }
    }

    public struct CodeAssistErrorEnvelope: Decodable, Sendable {
        public var error: CodeAssistErrorPayload
    }

    public struct AccountQuota: Codable, Equatable, Sendable {
        public var profileID: String
        public var email: String
        public var projectID: String
        public var tierID: String?
        public var tierName: String?
        public var hasOnboarded: Bool
        public var modelQuotas: [String: [ModelQuota]]
        public var experimentFlags: [Int: Bool]
        public var dailyQuotaExhausted: Bool
        public var lastQuotaRefresh: Date?

        public init(
            profileID: String,
            email: String,
            projectID: String,
            tierID: String? = nil,
            tierName: String? = nil,
            hasOnboarded: Bool = false,
            modelQuotas: [String: [ModelQuota]] = [:],
            experimentFlags: [Int: Bool] = [:],
            dailyQuotaExhausted: Bool = false,
            lastQuotaRefresh: Date? = nil
        ) {
            self.profileID = profileID
            self.email = email
            self.projectID = projectID
            self.tierID = tierID
            self.tierName = tierName
            self.hasOnboarded = hasOnboarded
            self.modelQuotas = modelQuotas
            self.experimentFlags = experimentFlags
            self.dailyQuotaExhausted = dailyQuotaExhausted
            self.lastQuotaRefresh = lastQuotaRefresh
        }
    }

    public struct ModelQuota: Codable, Equatable, Sendable {
        public var remainingAmount: String?
        public var remainingFraction: Double?
        public var resetTime: Date?
        public var tokenType: String?

        public init(
            remainingAmount: String? = nil,
            remainingFraction: Double? = nil,
            resetTime: Date? = nil,
            tokenType: String? = nil
        ) {
            self.remainingAmount = remainingAmount
            self.remainingFraction = remainingFraction
            self.resetTime = resetTime
            self.tokenType = tokenType
        }

        public var isExhausted: Bool {
            if let fraction = remainingFraction { return fraction <= 0 }
            if let amount = remainingAmount.flatMap(Int64.init) { return amount <= 0 }
            return false
        }

        public func isExhausted(at date: Date) -> Bool {
            guard isExhausted else { return false }
            return resetTime.map { $0 > date } ?? true
        }

        public var isNearExhaustion: Bool {
            if let fraction = remainingFraction { return fraction <= 0.1 }
            return false
        }
    }

}
