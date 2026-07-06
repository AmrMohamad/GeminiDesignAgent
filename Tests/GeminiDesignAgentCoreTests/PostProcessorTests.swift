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
}
