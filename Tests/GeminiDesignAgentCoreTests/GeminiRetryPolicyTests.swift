import XCTest
@testable import GeminiDesignAgentCore

final class GeminiRetryPolicyTests: XCTestCase {
    func testCalculatedDelayUsesBoundedDeterministicJitter() {
        XCTAssertEqual(GeminiRetryPolicy(randomUnit: { 0 }).calculatedDelay(attempt: 2), .seconds(2))
        XCTAssertEqual(GeminiRetryPolicy(randomUnit: { 1 }).calculatedDelay(attempt: 2), .seconds(4))
        XCTAssertEqual(GeminiRetryPolicy(randomUnit: { 4 }).calculatedDelay(attempt: 20), .seconds(32))
    }
}
