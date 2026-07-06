import XCTest
@testable import GeminiDesignAgentCore

final class PromptBuilderTests: XCTestCase {
    func testBuildPrompt_includesScreenName() {
        let imageInfo = ImageInfo(width: 1440, height: 1024, mimeType: "image/png", fileSize: 1000, format: .png)
        let memory = MemoryInjection()

        let (system, user) = DesignPromptBuilder.build(
            screenName: "Home Screen",
            request: "Extract layout details",
            imageInfo: imageInfo,
            memory: memory
        )

        XCTAssertTrue(user.contains("Home Screen"))
        XCTAssertTrue(user.contains("1440 x 1024 px"))
        XCTAssertTrue(user.contains("Extract layout details"))
        XCTAssertTrue(system.contains("senior UI engineer"))
    }

    func testBuildPrompt_includesMemoryProfile() {
        let imageInfo = ImageInfo(width: 100, height: 100, mimeType: "image/png", fileSize: 1000, format: .png)
        let profile = ProjectProfile(
            projectId: "proj_1",
            projectName: "Test",
            styleSummary: "Clean ecommerce style"
        )
        let memory = MemoryInjection(projectProfile: profile)

        let (_, user) = DesignPromptBuilder.build(
            screenName: "Test Screen",
            request: "Analyze",
            imageInfo: imageInfo,
            memory: memory
        )

        XCTAssertTrue(user.contains("Clean ecommerce style"))
        XCTAssertTrue(user.contains("<profile>"))
    }

    func testBuildPrompt_includesMemoryAtoms() {
        let imageInfo = ImageInfo(width: 100, height: 100, mimeType: "image/png", fileSize: 1000, format: .png)
        let atom = MemoryAtom(
            id: "mem_1",
            projectId: "proj_1",
            type: .designToken,
            scope: .global,
            priority: 90,
            content: "Primary button uses 12px radius"
        )
        let result = MemorySearchResult(atom: atom, score: 10.0)
        let memory = MemoryInjection(atoms: [result])

        let (_, user) = DesignPromptBuilder.build(
            screenName: "Test",
            request: "Analyze",
            imageInfo: imageInfo,
            memory: memory
        )

        XCTAssertTrue(user.contains("Primary button uses 12px radius"))
        XCTAssertTrue(user.contains("[mem_1]"))
    }
}
