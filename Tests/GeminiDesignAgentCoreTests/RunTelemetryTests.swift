import XCTest
@testable import GeminiDesignAgentCore

final class RunTelemetryTests: XCTestCase {
    func testProductionDefaultUsesStableGemini35Flash() {
        XCTAssertEqual(GDAContract.defaultModel, "gemini-3.5-flash")
    }

    func testVersionContractUsesStableSnakeCaseKeys() throws {
        let data = try JSON.encoder.encode(GDAContract.version)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["version"] as? String, "0.1.0")
        XCTAssertEqual(object["skill_protocol_version"] as? String, "1")
        XCTAssertEqual(object["gemini_api_version"] as? String, "v1")
        XCTAssertEqual(object["prompt_schema_version"] as? String, "1.2")
        XCTAssertEqual(object["analysis_schema_version"] as? String, "1.0")
        XCTAssertEqual(object["database_schema_version"] as? Int, GDAContract.databaseSchemaVersion)
        XCTAssertEqual(object["handoff_schema_version"] as? String, "gda.design_handoff.v1")
    }

    func testKnownModelProducesConservativeDatedCostEstimate() throws {
        let usage = RunTokenUsage(
            inputTokens: 100,
            outputTokens: 300,
            thoughtTokens: 50,
            cachedTokens: 25,
            totalTokens: 475
        )
        let estimate = try XCTUnwrap(RunCostEstimator.estimate(model: GDAContract.defaultModel, usage: usage))

        XCTAssertEqual(estimate.upperBoundEstimatedCostUSD, 0.00330, accuracy: 0.0000000001)
        XCTAssertEqual(estimate.pricingVersion, "google-gemini-pricing-2026-07-10")
        let telemetry = RunTelemetry(
            model: GDAContract.defaultModel,
            usage: GeminiUsageMetadata(inputTokenCount: 100, outputTokenCount: 300, thoughtTokenCount: 50),
            durationMs: 10
        )
        XCTAssertNil(telemetry.metrics.costEstimateDiagnostic)
        XCTAssertTrue(telemetry.metrics.nonFatalDiagnostics.isEmpty)
    }

    func testCostEstimateStaysUnknownForUnknownModelOrIncompleteUsage() {
        let complete = RunTokenUsage(inputTokens: 100, outputTokens: 200)
        XCTAssertNil(RunCostEstimator.estimate(model: "future-model", usage: complete))
        XCTAssertNil(RunCostEstimator.estimate(
            model: GDAContract.defaultModel,
            usage: RunTokenUsage(inputTokens: 100)
        ))
        XCTAssertNil(RunCostEstimator.estimate(
            model: GDAContract.defaultModel,
            usage: RunTokenUsage(inputTokens: -1, outputTokens: 20)
        ))

        for telemetry in [
            RunTelemetry(
                model: "future-model",
                usage: GeminiUsageMetadata(inputTokenCount: 100, outputTokenCount: 200),
                durationMs: 10
            ),
            RunTelemetry(model: GDAContract.defaultModel, usage: nil, durationMs: 10)
        ] {
            XCTAssertNil(telemetry.metrics.upperBoundEstimatedCostUSD)
            XCTAssertNil(telemetry.metrics.pricingVersion)
            XCTAssertEqual(telemetry.metrics.costEstimateDiagnostic, "COST_ESTIMATE_UNAVAILABLE")
            XCTAssertEqual(telemetry.metrics.nonFatalDiagnostics, [.costEstimateUnavailable])
            XCTAssertFalse(telemetry.metrics.nonFatalDiagnostics[0].retryable)
        }
    }

    func testMergedGeminiUsageSumsRepairCallAndPreservesBothRawPayloads() throws {
        let firstRaw: JSONValue = .object([
            "total_input_tokens": .int(10),
            "total_output_tokens": .int(20),
            "first_future_field": .bool(true)
        ])
        let repairRaw: JSONValue = .object([
            "total_input_tokens": .int(5),
            "total_output_tokens": .int(8),
            "total_thought_tokens": .int(3),
            "repair_future_field": .string("kept")
        ])
        let merged = GeminiUsageMetadata(
            inputTokenCount: 10,
            outputTokenCount: 20,
            raw: firstRaw
        ).merging(GeminiUsageMetadata(
            inputTokenCount: 5,
            outputTokenCount: 8,
            thoughtTokenCount: 3,
            raw: repairRaw
        ))

        XCTAssertEqual(merged.inputTokenCount, 15)
        XCTAssertEqual(merged.outputTokenCount, 28)
        XCTAssertEqual(merged.thoughtTokenCount, 3)
        XCTAssertTrue(merged.rawJSONString?.contains("first_future_field") == true)
        XCTAssertTrue(merged.rawJSONString?.contains("repair_future_field") == true)
    }

    func testRunStatisticsAggregateDurationsTokensCostsAndGroups() throws {
        let now = Date()
        let runs = [
            makeRun(id: "one", model: "model-a", status: "completed", durationMs: 100, input: 10, output: 20, thought: 2, total: 32, cost: 0.1),
            makeRun(id: "two", model: "model-a", status: "completed", durationMs: 200, input: 20, output: 30, thought: 3, total: 53, cost: 0.2),
            makeRun(id: "three", model: "model-b", status: "failed", durationMs: 300, input: nil, output: nil, thought: nil, total: nil, cost: nil),
            makeRun(id: "four", model: "model-b", status: "started", durationMs: 400, input: 40, output: 50, thought: 5, total: 95, cost: nil)
        ]

        let statistics = RunStatistics.calculate(
            runs: runs,
            requestedSinceDays: 30,
            since: now.addingTimeInterval(-2_592_000),
            generatedAt: now
        )

        XCTAssertEqual(statistics.totalRuns, 4)
        XCTAssertEqual(statistics.completedRuns, 2)
        XCTAssertEqual(statistics.failedRuns, 1)
        XCTAssertEqual(statistics.unpricedRuns, 2)
        XCTAssertEqual(statistics.inputTokens, 70)
        XCTAssertEqual(statistics.outputTokens, 100)
        XCTAssertEqual(statistics.thoughtTokens, 10)
        XCTAssertEqual(statistics.totalTokens, 180)
        XCTAssertEqual(statistics.averageDurationMs, 250)
        XCTAssertEqual(statistics.p95DurationMs, 400)
        XCTAssertEqual(statistics.upperBoundEstimatedCostUSD, 0.3, accuracy: 0.0000001)
        XCTAssertEqual(statistics.byModel.map(\.value), ["model-a", "model-b"])
        XCTAssertEqual(statistics.byModel.first?.runCount, 2)
        XCTAssertEqual(statistics.byStatus.map(\.value), ["completed", "failed", "started"])
    }

    private func makeRun(
        id: String,
        model: String,
        status: String,
        durationMs: Int?,
        input: Int?,
        output: Int?,
        thought: Int?,
        total: Int?,
        cost: Double?
    ) -> RunRecord {
        RunRecord(
            id: id,
            projectId: "project",
            sessionId: "session",
            screenName: "Screen",
            imagePath: "/tmp/screen.png",
            model: model,
            request: "Analyze",
            status: status,
            startedAt: Date(),
            completedAt: nil,
            error: nil,
            gdaVersion: GDAContract.productVersion,
            apiVersion: GDAContract.geminiAPIVersion,
            promptSchemaVersion: GDAContract.promptSchemaVersion,
            analysisSchemaVersion: GDAContract.analysisSchemaVersion,
            inputTokens: input,
            outputTokens: output,
            thoughtTokens: thought,
            cachedTokens: nil,
            totalTokens: total,
            durationMs: durationMs,
            usageJSON: nil,
            estimatedCostUSD: cost,
            pricingVersion: cost == nil ? nil : RunCostEstimator.pricingVersion
        )
    }
}
