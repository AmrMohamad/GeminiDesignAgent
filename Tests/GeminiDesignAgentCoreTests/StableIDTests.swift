import XCTest
@testable import GeminiDesignAgentCore

final class StableIDTests: XCTestCase {
    func testRunID_hasCorrectPrefix() {
        let id = StableID.run()
        XCTAssertTrue(id.hasPrefix("run_"))
        XCTAssertEqual(id.count, 16) // "run_" + 12 chars
    }

    func testEvidenceID_hasCorrectPrefix() {
        let id = StableID.evidence()
        XCTAssertTrue(id.hasPrefix("evi_"))
    }

    func testMemoryID_hasCorrectPrefix() {
        let id = StableID.memory()
        XCTAssertTrue(id.hasPrefix("mem_"))
    }

    func testSceneID_hasCorrectPrefix() {
        let id = StableID.scene()
        XCTAssertTrue(id.hasPrefix("scene_"))
    }

    func testProjectID_hasCorrectPrefix() {
        let id = StableID.project()
        XCTAssertTrue(id.hasPrefix("proj_"))
    }

    func testIDsAreUnique() {
        let ids = Set((0..<100).map { _ in StableID.memory() })
        XCTAssertEqual(ids.count, 100)
    }
}
