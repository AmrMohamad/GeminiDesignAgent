import Foundation
import XCTest
@testable import GeminiDesignAgentCore

final class CodeAssistModelsTests: XCTestCase {
    func testQuotaBucketExhaustionExpiresAtResetTime() {
        let now = Date(timeIntervalSince1970: 1_000)
        let active = CodeAssist.ModelQuota(remainingFraction: 0, resetTime: now.addingTimeInterval(60))
        let expired = CodeAssist.ModelQuota(remainingFraction: 0, resetTime: now.addingTimeInterval(-1))

        XCTAssertTrue(active.isExhausted(at: now))
        XCTAssertFalse(expired.isExhausted(at: now))
    }

    func testExperimentFlagsDecodeAuthoritativeWireShape() throws {
        let data = Data(#"{"experimentIds":[45760185],"flags":[{"flagId":45768879,"boolValue":true}]}"#.utf8)
        let response = try JSON.decoder.decode(CodeAssist.ListExperimentsResponse.self, from: data)

        XCTAssertEqual(response.experimentIds, [CodeAssist.ExperimentFlagID.gemini31ProLaunched])
        XCTAssertEqual(response.flags?.first?.flagId, CodeAssist.ExperimentFlagID.proModelNoAccess)
        XCTAssertEqual(response.flags?.first?.boolValue, true)
    }
}
