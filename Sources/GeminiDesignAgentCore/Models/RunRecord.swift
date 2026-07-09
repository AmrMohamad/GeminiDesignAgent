import Foundation

public struct RunRecord: Codable, Sendable {
    public var id: String
    public var projectId: String
    public var sessionId: String
    public var screenName: String?
    public var imagePath: String
    public var model: String
    public var request: String
    public var status: String
    public var startedAt: Date
    public var completedAt: Date?
    public var error: String?
    public var gdaVersion: String?
    public var apiVersion: String?
    public var promptSchemaVersion: String?
    public var analysisSchemaVersion: String?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var thoughtTokens: Int?
    public var cachedTokens: Int?
    public var totalTokens: Int?
    public var durationMs: Int?
    public var usageJSON: String?
    public var estimatedCostUSD: Double?
    public var pricingVersion: String?
}

public struct RunStatistics: Codable, Equatable, Sendable {
    public var requestedSinceDays: Int
    public var since: Date
    public var generatedAt: Date
    public var totalRuns: Int
    public var completedRuns: Int
    public var failedRuns: Int
    public var unpricedRuns: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var thoughtTokens: Int
    public var totalTokens: Int
    public var averageDurationMs: Double?
    public var p95DurationMs: Int?
    public var upperBoundEstimatedCostUSD: Double
    public var byModel: [RunStatisticsGroup]
    public var byStatus: [RunStatisticsGroup]

    public static func calculate(
        runs: [RunRecord],
        requestedSinceDays: Int,
        since: Date,
        generatedAt: Date = Date()
    ) -> RunStatistics {
        let durations = runs.compactMap(\.durationMs).sorted()
        let averageDuration = durations.isEmpty
            ? nil
            : durations.reduce(0.0) { $0 + Double($1) } / Double(durations.count)
        let p95Duration: Int? = durations.isEmpty
            ? nil
            : durations[max(0, Int(ceil(Double(durations.count) * 0.95)) - 1)]

        return RunStatistics(
            requestedSinceDays: requestedSinceDays,
            since: since,
            generatedAt: generatedAt,
            totalRuns: runs.count,
            completedRuns: runs.filter { $0.status == "completed" }.count,
            failedRuns: runs.filter { $0.status == "failed" }.count,
            unpricedRuns: runs.filter { $0.estimatedCostUSD == nil }.count,
            inputTokens: runs.compactMap(\.inputTokens).reduce(0, +),
            outputTokens: runs.compactMap(\.outputTokens).reduce(0, +),
            thoughtTokens: runs.compactMap(\.thoughtTokens).reduce(0, +),
            totalTokens: runs.compactMap(\.totalTokens).reduce(0, +),
            averageDurationMs: averageDuration,
            p95DurationMs: p95Duration,
            upperBoundEstimatedCostUSD: runs.compactMap(\.estimatedCostUSD).reduce(0, +),
            byModel: grouped(runs, key: \.model),
            byStatus: grouped(runs, key: \.status)
        )
    }

    private static func grouped(
        _ runs: [RunRecord],
        key: KeyPath<RunRecord, String>
    ) -> [RunStatisticsGroup] {
        let groupedRuns = Dictionary(grouping: runs) { run in
            run[keyPath: key]
        }
        var groups: [RunStatisticsGroup] = []
        groups.reserveCapacity(groupedRuns.count)

        for (value, runsForValue) in groupedRuns {
            let group = RunStatisticsGroup(
                value: value,
                runCount: runsForValue.count,
                unpricedRuns: runsForValue.filter { $0.estimatedCostUSD == nil }.count,
                inputTokens: runsForValue.compactMap(\.inputTokens).reduce(0, +),
                outputTokens: runsForValue.compactMap(\.outputTokens).reduce(0, +),
                thoughtTokens: runsForValue.compactMap(\.thoughtTokens).reduce(0, +),
                totalTokens: runsForValue.compactMap(\.totalTokens).reduce(0, +),
                upperBoundEstimatedCostUSD: runsForValue.compactMap(\.estimatedCostUSD).reduce(0, +)
            )
            groups.append(group)
        }

        return groups.sorted { $0.value < $1.value }
    }

    enum CodingKeys: String, CodingKey {
        case requestedSinceDays = "requested_since_days"
        case since
        case generatedAt = "generated_at"
        case totalRuns = "total_runs"
        case completedRuns = "completed_runs"
        case failedRuns = "failed_runs"
        case unpricedRuns = "unpriced_runs"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case thoughtTokens = "thought_tokens"
        case totalTokens = "total_tokens"
        case averageDurationMs = "average_duration_ms"
        case p95DurationMs = "p95_duration_ms"
        case upperBoundEstimatedCostUSD = "upper_bound_estimated_cost_usd"
        case byModel = "by_model"
        case byStatus = "by_status"
    }
}

public struct RunStatisticsGroup: Codable, Equatable, Sendable {
    public var value: String
    public var runCount: Int
    public var unpricedRuns: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var thoughtTokens: Int
    public var totalTokens: Int
    public var upperBoundEstimatedCostUSD: Double

    enum CodingKeys: String, CodingKey {
        case value
        case runCount = "run_count"
        case unpricedRuns = "unpriced_runs"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case thoughtTokens = "thought_tokens"
        case totalTokens = "total_tokens"
        case upperBoundEstimatedCostUSD = "upper_bound_estimated_cost_usd"
    }
}
