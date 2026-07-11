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

    func testZeroAreaAndOutOfRangeElementsAreDropped() {
        let result = validate(elements: [
            element("zero", bbox: BBox1000(ymin: 0, xmin: 0, ymax: 0, xmax: 10)),
            element("range", bbox: BBox1000(ymin: 0, xmin: -1, ymax: 10, xmax: 10)),
        ])
        XCTAssertTrue(result.elements.isEmpty)
        XCTAssertTrue(result.diagnostics.contains("element.dropped.invalid_geometry"))
    }

    func testDuplicateElementIDIsDropped() {
        let result = validate(elements: [element("same"), element("same")])
        XCTAssertEqual(result.elements.map(\.id), ["same"])
        XCTAssertTrue(result.diagnostics.contains("element.dropped.duplicate_id"))
    }

    func testInvalidElementMeasurementsAreRemovedWithDiagnostics() throws {
        var value = element("measured")
        value.typography = TypographyGuess(fontSizePx: -1, lineHeightPx: -1, letterSpacingPx: 65, colorHex: "bad")
        value.spacing = SpacingGuess(top: -1)
        value.borderRadiusPx = -1
        value.colorsHex = ["bad", "#aabbccdd"]
        let result = validate(elements: [value])
        let normalized = try XCTUnwrap(result.elements.first)
        XCTAssertNil(normalized.typography?.fontSizePx)
        XCTAssertNil(normalized.typography?.lineHeightPx)
        XCTAssertNil(normalized.typography?.letterSpacingPx)
        XCTAssertNil(normalized.typography?.colorHex)
        XCTAssertNil(normalized.spacing?.top)
        XCTAssertNil(normalized.borderRadiusPx)
        XCTAssertEqual(normalized.colorsHex, ["#AABBCCDD"])
        XCTAssertTrue(result.diagnostics.contains("element.typography.font_size_removed"))
        XCTAssertTrue(result.diagnostics.contains("element.spacing.invalid_removed"))
        XCTAssertTrue(result.diagnostics.contains("element.radius.invalid_removed"))
    }

    func testInvalidTokensAreRemovedSortedAndDiagnosed() {
        let analysis = DesignAnalysis(
            tokens: DesignTokens(
                colors: [NamedColorToken(name: "bad", hex: "nope"), NamedColorToken(name: "ok", hex: "#aabbcc", confidence: 2)],
                typography: [TypographyToken(name: "bad", fontSizePx: -1)],
                spacingScalePx: [8, -1, 8], radiiPx: [12, -1, 12], shadows: [" ", " shadow ", "shadow"]
            ),
            elements: [element("valid")], memoryWrites: []
        )
        let result = DesignAnalysisPostProcessor.validate(analysis)
        XCTAssertEqual(result.tokens.colors.map(\.hex), ["#AABBCC"])
        XCTAssertEqual(result.tokens.colors.first?.confidence, 1)
        XCTAssertTrue(result.tokens.typography.isEmpty)
        XCTAssertEqual(result.tokens.spacingScalePx, [8])
        XCTAssertEqual(result.tokens.radiiPx, [12])
        XCTAssertEqual(result.tokens.shadows, ["shadow"])
        XCTAssertTrue(result.diagnostics.contains("token.color.invalid_removed"))
        XCTAssertTrue(result.diagnostics.contains("token.spacing.invalid_removed"))
        XCTAssertTrue(result.diagnostics.contains("token.radius.invalid_removed"))
        XCTAssertTrue(result.diagnostics.contains("token.shadow.invalid_removed"))
    }

    func testComponentsFilterReferencesDuplicatesAndConfidence() throws {
        let components = [
            ComponentCandidate(id: "component", name: "Card", elementIds: ["valid", "missing", "valid"], confidence: -1),
            ComponentCandidate(id: "component", name: "Duplicate"),
        ]
        let result = DesignAnalysisPostProcessor.validate(DesignAnalysis(elements: [element("valid")], components: components, memoryWrites: []))
        let component = try XCTUnwrap(result.components.first)
        XCTAssertEqual(component.elementIds, ["valid"])
        XCTAssertEqual(component.confidence, 0)
        XCTAssertEqual(result.components.count, 1)
        XCTAssertTrue(result.diagnostics.contains("component.element_reference.invalid_removed"))
        XCTAssertTrue(result.diagnostics.contains("component.dropped.duplicate_id"))
    }

    func testHierarchyDepthCyclesDuplicatesAndMissingElementsAreRemoved() throws {
        let duplicateChild = HierarchyNode(id: "root", elementId: "valid", depth: 9)
        let missingChild = HierarchyNode(id: "missing", elementId: "absent", depth: 9)
        let root = HierarchyNode(id: "root", elementId: "valid", children: [duplicateChild, missingChild], depth: 99)
        let result = DesignAnalysisPostProcessor.validate(DesignAnalysis(elements: [element("valid")], hierarchy: [root], memoryWrites: []))
        XCTAssertEqual(try XCTUnwrap(result.hierarchy.first).depth, 0)
        XCTAssertTrue(try XCTUnwrap(result.hierarchy.first).children.isEmpty)
        XCTAssertTrue(result.diagnostics.contains("hierarchy.depth.recomputed"))
        XCTAssertTrue(result.diagnostics.contains("hierarchy.invalid_removed"))
    }

    func testConfidenceValuesAreClamped() throws {
        var value = element("valid")
        value.bbox1000.confidence = -2
        value.typography = TypographyGuess(confidence: 2)
        value.spacing = SpacingGuess(confidence: -1)
        let result = validate(elements: [value])
        let normalized = try XCTUnwrap(result.elements.first)
        XCTAssertEqual(normalized.bbox1000.confidence, 0)
        XCTAssertEqual(normalized.typography?.confidence, 1)
        XCTAssertEqual(normalized.spacing?.confidence, 0)
    }

    func testValidationOutputIsDeterministic() throws {
        let input = DesignAnalysis(tokens: DesignTokens(spacingScalePx: [8, -1, 8]), elements: [element("valid")], memoryWrites: [])
        let first = DesignAnalysisPostProcessor.validate(input)
        let second = DesignAnalysisPostProcessor.validate(input)
        XCTAssertEqual(try JSON.encoder.encode(first), try JSON.encoder.encode(second))
    }

    func testSeededInvalidAnalysesNeverLeakInvalidGeometryOrReferences() {
        var state: UInt64 = 0xC0FFEE
        func next(_ upperBound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return Int((state >> 32) % UInt64(upperBound))
        }
        for _ in 0..<100 {
            let elements = (0..<40).map { index in
                element("e\(index)", bbox: BBox1000(
                    ymin: next(1_300) - 150, xmin: next(1_300) - 150,
                    ymax: next(1_300) - 150, xmax: next(1_300) - 150
                ))
            }
            let result = validate(elements: elements)
            let ids = Set(result.elements.map(\.id))
            for value in result.elements {
                XCTAssertTrue((0...999).contains(value.bbox1000.xmin))
                XCTAssertTrue((1...1_000).contains(value.bbox1000.xmax))
                XCTAssertLessThan(value.bbox1000.xmin, value.bbox1000.xmax)
                XCTAssertLessThan(value.bbox1000.ymin, value.bbox1000.ymax)
                XCTAssertTrue(value.children.allSatisfy(ids.contains))
                XCTAssertTrue((0...1).contains(value.bbox1000.confidence))
            }
        }
    }

    private func validate(elements: [DesignElement]) -> DesignAnalysis {
        DesignAnalysisPostProcessor.validate(DesignAnalysis(elements: elements, memoryWrites: []))
    }

    private func element(_ id: String, bbox: BBox1000 = BBox1000(ymin: 0, xmin: 0, ymax: 100, xmax: 100)) -> DesignElement {
        DesignElement(id: id, type: .card, label: id, bbox1000: bbox)
    }
}
