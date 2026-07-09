import Foundation

public struct RunTokenUsage: Codable, Equatable, Sendable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var thoughtTokens: Int?
    public var cachedTokens: Int?
    public var totalTokens: Int?

    public init(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        thoughtTokens: Int? = nil,
        cachedTokens: Int? = nil,
        totalTokens: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.thoughtTokens = thoughtTokens
        self.cachedTokens = cachedTokens
        self.totalTokens = totalTokens
    }

    public init(_ usage: GeminiUsageMetadata) {
        self.init(
            inputTokens: usage.inputTokenCount,
            outputTokens: usage.outputTokenCount,
            thoughtTokens: usage.thoughtTokenCount,
            cachedTokens: usage.cachedTokenCount,
            totalTokens: usage.totalTokenCount
        )
    }

    public var hasAnyValue: Bool {
        inputTokens != nil || outputTokens != nil || thoughtTokens != nil || cachedTokens != nil || totalTokens != nil
    }

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case thoughtTokens = "thought_tokens"
        case cachedTokens = "cached_tokens"
        case totalTokens = "total_tokens"
    }
}

public struct RunMetrics: Codable, Equatable, Sendable {
    public var durationMs: Int
    public var gdaVersion: String
    public var apiVersion: String
    public var promptSchemaVersion: String
    public var analysisSchemaVersion: String
    public var upperBoundEstimatedCostUSD: Double?
    public var pricingVersion: String?
    public var costEstimateDiagnostic: String?

    public var nonFatalDiagnostics: [RunDiagnostic] {
        guard costEstimateDiagnostic == RunCostEstimator.unavailableDiagnostic else { return [] }
        return [RunDiagnostic.costEstimateUnavailable]
    }

    enum CodingKeys: String, CodingKey {
        case durationMs = "duration_ms"
        case gdaVersion = "gda_version"
        case apiVersion = "api_version"
        case promptSchemaVersion = "prompt_schema_version"
        case analysisSchemaVersion = "analysis_schema_version"
        case upperBoundEstimatedCostUSD = "upper_bound_estimated_cost_usd"
        case pricingVersion = "pricing_version"
        case costEstimateDiagnostic = "cost_estimate_diagnostic"
    }
}

public struct RunDiagnostic: Codable, Equatable, Sendable {
    public var code: String
    public var title: String
    public var message: String
    public var resolution: String
    public var retryable: Bool

    public static let costEstimateUnavailable = RunDiagnostic(
        code: RunCostEstimator.unavailableDiagnostic,
        title: "Cost estimate is unavailable",
        message: "This run could not be priced because its model or token usage is not in the dated pricing catalog.",
        resolution: "Treat cost as unknown. Review the model and usage fields before adding an official dated price.",
        retryable: false
    )
}

public struct RunTelemetry: Equatable, Sendable {
    public var usage: RunTokenUsage?
    public var metrics: RunMetrics
    public var usageJSON: String?

    public init(model: String, usage: GeminiUsageMetadata?, durationMs: Int) {
        let tokenUsage = usage.map(RunTokenUsage.init)
        let estimate = RunCostEstimator.estimate(model: model, usage: tokenUsage)

        self.usage = tokenUsage?.hasAnyValue == true ? tokenUsage : nil
        self.metrics = RunMetrics(
            durationMs: max(0, durationMs),
            gdaVersion: GDAContract.productVersion,
            apiVersion: GDAContract.geminiAPIVersion,
            promptSchemaVersion: GDAContract.promptSchemaVersion,
            analysisSchemaVersion: GDAContract.analysisSchemaVersion,
            upperBoundEstimatedCostUSD: estimate?.upperBoundEstimatedCostUSD,
            pricingVersion: estimate?.pricingVersion,
            costEstimateDiagnostic: estimate == nil ? RunCostEstimator.unavailableDiagnostic : nil
        )
        self.usageJSON = usage?.rawJSONString
    }
}

public struct RunCostEstimate: Equatable, Sendable {
    public var upperBoundEstimatedCostUSD: Double
    public var pricingVersion: String
}

public enum RunCostEstimator {
    public static let pricingVersion = "google-gemini-pricing-2026-07-10"
    public static let unavailableDiagnostic = "COST_ESTIMATE_UNAVAILABLE"

    private static let inputUSDPerMillionTokens = 0.30
    private static let outputUSDPerMillionTokens = 2.50

    public static func estimate(model: String, usage: RunTokenUsage?) -> RunCostEstimate? {
        guard model == GDAContract.defaultModel,
              let usage,
              let inputTokens = usage.inputTokens,
              let outputTokens = usage.outputTokens,
              inputTokens >= 0,
              outputTokens >= 0,
              (usage.thoughtTokens ?? 0) >= 0 else {
            return nil
        }

        let thoughtTokens = usage.thoughtTokens ?? 0
        let inputCost = Double(inputTokens) / 1_000_000 * inputUSDPerMillionTokens
        let outputCost = (Double(outputTokens) + Double(thoughtTokens)) / 1_000_000 * outputUSDPerMillionTokens
        return RunCostEstimate(
            upperBoundEstimatedCostUSD: inputCost + outputCost,
            pricingVersion: pricingVersion
        )
    }
}
