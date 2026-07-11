import XCTest
@testable import GeminiDesignAgentCore

final class PostProcessorTests: XCTestCase {
    func testFillPixelBoxes() {
        let element = DesignElement(
            id: "el_1",
            type: .button,
            label: "Test",
            bbox1000: BBox1000(ymin: 0, xmin: 0, ymax: 500, xmax: 500)
        )
        let analysis = DesignAnalysis(
            summary: "Test",
            elements: [element],
            memoryWrites: []
        )

        let result = DesignAnalysisPostProcessor.fillPixelBoxes(analysis, imageWidth: 1440, imageHeight: 1024)

        XCTAssertEqual(result.elements.first?.bboxPx?.x, 0)
        XCTAssertEqual(result.elements.first?.bboxPx?.y, 0)
        XCTAssertEqual(result.elements.first?.bboxPx?.width, 720)
        XCTAssertEqual(result.elements.first?.bboxPx?.height, 512)
    }

    func testValidationRemovesInvalidMeasurementsAndNormalizesHierarchy() {
        let valid = DesignElement(
            id: "valid",
            type: .text,
            label: "Title",
            bbox1000: BBox1000(ymin: 0, xmin: 0, ymax: 100, xmax: 100),
            colorsHex: ["#aabbcc", "invalid"],
            typography: TypographyGuess(fontSizePx: -1, lineHeightPx: 2_000, letterSpacingPx: 100, confidence: 2),
            spacing: SpacingGuess(top: -1, right: 8, confidence: -1),
            borderRadiusPx: -2,
            children: ["missing", "valid"]
        )
        let invalid = DesignElement(
            id: "invalid",
            type: .button,
            label: "Invalid",
            bbox1000: BBox1000(ymin: 0, xmin: 0, ymax: 0, xmax: 100)
        )
        let analysis = DesignAnalysis(
            summary: "Test",
            tokens: DesignTokens(
                colors: [NamedColorToken(name: "Accent", hex: "#11223344", confidence: 2)],
                typography: [TypographyToken(name: "Broken", fontSizePx: -1, lineHeightPx: -1)],
                spacingScalePx: [-1, 8, 8, 5_000],
                radiiPx: [-1, 12, 5_000],
                shadows: ["  ", "0 1px 2px #000", "0 1px 2px #000"]
            ),
            elements: [valid, invalid],
            hierarchy: [HierarchyNode(id: "root", elementId: "valid", depth: 99)],
            memoryWrites: []
        )

        let result = DesignAnalysisPostProcessor.validate(analysis)

        XCTAssertEqual(result.elements.map(\.id), ["valid"])
        XCTAssertEqual(result.elements[0].colorsHex, ["#AABBCC"])
        XCTAssertNil(result.elements[0].typography?.fontSizePx)
        XCTAssertNil(result.elements[0].typography?.lineHeightPx)
        XCTAssertNil(result.elements[0].typography?.letterSpacingPx)
        XCTAssertNil(result.elements[0].spacing?.top)
        XCTAssertEqual(result.elements[0].spacing?.right, 8)
        XCTAssertNil(result.elements[0].borderRadiusPx)
        XCTAssertTrue(result.elements[0].children.isEmpty)
        XCTAssertEqual(result.tokens.colors.map(\.hex), ["#11223344"])
        XCTAssertTrue(result.tokens.typography.isEmpty)
        XCTAssertEqual(result.tokens.spacingScalePx, [8])
        XCTAssertEqual(result.tokens.radiiPx, [12])
        XCTAssertEqual(result.tokens.shadows, ["0 1px 2px #000"])
        XCTAssertEqual(result.hierarchy.first?.depth, 0)
        XCTAssertTrue(result.diagnostics.contains("analysis.validation.modified"))
    }
}
