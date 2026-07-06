import XCTest
@testable import GeminiDesignAgentCore

final class MemoryRankingTests: XCTestCase {
    func testHigherPriorityBoostsScore() {
        let lowPriority = MemoryAtom(
            id: "mem_1",
            projectId: "proj_1",
            type: .designToken,
            scope: .global,
            priority: 10,
            content: "test"
        )
        let highPriority = MemoryAtom(
            id: "mem_2",
            projectId: "proj_1",
            type: .designToken,
            scope: .global,
            priority: 90,
            content: "test"
        )

        let query = MemoryQuery(text: "test", limit: 5)
        let lowScore = MemoryRanking.rank(bm25Score: 1.0, atom: lowPriority, query: query)
        let highScore = MemoryRanking.rank(bm25Score: 1.0, atom: highPriority, query: query)

        XCTAssertGreaterThan(highScore, lowScore)
    }

    func testSameScreenBoost() {
        let atom = MemoryAtom(
            id: "mem_1",
            projectId: "proj_1",
            type: .designToken,
            scope: .global,
            priority: 50,
            sceneName: "Home Screen",
            content: "test"
        )

        let queryWithScreen = MemoryQuery(text: "test", limit: 5, screenName: "Home Screen")
        let queryWithoutScreen = MemoryQuery(text: "test", limit: 5)

        let scoreWithScreen = MemoryRanking.rank(bm25Score: 1.0, atom: atom, query: queryWithScreen)
        let scoreWithoutScreen = MemoryRanking.rank(bm25Score: 1.0, atom: atom, query: queryWithoutScreen)

        XCTAssertGreaterThan(scoreWithScreen, scoreWithoutScreen)
    }

    func testRecencyBoost() {
        let oldAtom = MemoryAtom(
            id: "mem_1",
            projectId: "proj_1",
            type: .designToken,
            scope: .global,
            priority: 50,
            content: "test",
            createdAt: Date().addingTimeInterval(-86400 * 10)
        )
        let newAtom = MemoryAtom(
            id: "mem_2",
            projectId: "proj_1",
            type: .designToken,
            scope: .global,
            priority: 50,
            content: "test",
            createdAt: Date()
        )

        let query = MemoryQuery(text: "test", limit: 5)
        let oldScore = MemoryRanking.rank(bm25Score: 1.0, atom: oldAtom, query: query)
        let newScore = MemoryRanking.rank(bm25Score: 1.0, atom: newAtom, query: query)

        XCTAssertGreaterThan(newScore, oldScore)
    }
}
