import XCTest
@testable import GeminiDesignAgentCore

final class MemoryPromotionPolicyTests: XCTestCase {
    func testPromotionRequiresAllowedTypeTwoScreensAndIndependentEvidence() {
        let home = MemoryAtom(id: "home", projectId: "project", type: .designToken, scope: .screen, priority: 50, sceneName: "Home", content: "Primary button uses 12px radius", sourceEvidenceIds: ["evidence_home"], confidence: 0.9)
        let details = MemoryAtom(id: "details", projectId: "project", type: .designToken, scope: .screen, priority: 50, sceneName: "Details", content: "Primary button uses 12px radius", sourceEvidenceIds: ["evidence_details"], confidence: 0.9)

        XCTAssertTrue(MemoryPromotionPolicy.canPromote(candidate: details, supporting: home, matchingNormalizedContent: true))
        XCTAssertFalse(MemoryPromotionPolicy.canPromote(candidate: details, supporting: home, matchingNormalizedContent: false))

        var sameEvidence = details
        sameEvidence.sourceEvidenceIds = ["evidence_home"]
        XCTAssertFalse(MemoryPromotionPolicy.canPromote(candidate: sameEvidence, supporting: home, matchingNormalizedContent: true))

        var unsafe = details
        unsafe.type = .implementationInstruction
        XCTAssertFalse(MemoryPromotionPolicy.canPromote(candidate: unsafe, supporting: home, matchingNormalizedContent: true))
    }
}
