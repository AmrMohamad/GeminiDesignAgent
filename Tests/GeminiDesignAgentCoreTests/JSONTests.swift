import XCTest
@testable import GeminiDesignAgentCore

final class JSONTests: XCTestCase {
    func testEncodeDecodeDesignAnalysis() {
        let analysis = DesignAnalysis(
            schemaVersion: "1.0",
            summary: "Test summary",
            tokens: DesignTokens(
                colors: [NamedColorToken(name: "primary", hex: "#D7A84F")],
                typography: [],
                spacingScalePx: [4, 8, 12, 16],
                radiiPx: [8, 12],
                shadows: []
            ),
            elements: [
                DesignElement(
                    id: "el_1",
                    type: .button,
                    label: "Primary CTA",
                    bbox1000: BBox1000(ymin: 100, xmin: 200, ymax: 300, xmax: 400)
                )
            ],
            memoryWrites: []
        )

        let data = try! JSON.encoder.encode(analysis)
        let decoded = try! JSON.decoder.decode(DesignAnalysis.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, "1.0")
        XCTAssertEqual(decoded.summary, "Test summary")
        XCTAssertEqual(decoded.tokens.colors.first?.hex, "#D7A84F")
        XCTAssertEqual(decoded.tokens.spacingScalePx, [4, 8, 12, 16])
        XCTAssertEqual(decoded.elements.count, 1)
        XCTAssertEqual(decoded.elements.first?.type, .button)
    }

    func testEncodeDecodeMemoryAtom() {
        let atom = MemoryAtom(
            id: "mem_1",
            projectId: "proj_1",
            type: .designToken,
            scope: .global,
            priority: 90,
            content: "Primary brand color is #D7A84F",
            tags: ["color", "brand"],
            confidence: 0.95
        )

        let data = try! JSON.encoder.encode(atom)
        let decoded = try! JSON.decoder.decode(MemoryAtom.self, from: data)

        XCTAssertEqual(decoded.id, "mem_1")
        XCTAssertEqual(decoded.content, "Primary brand color is #D7A84F")
        XCTAssertEqual(decoded.tags, ["color", "brand"])
    }
}
