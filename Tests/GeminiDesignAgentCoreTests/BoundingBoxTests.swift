import XCTest
@testable import GeminiDesignAgentCore

final class BoundingBoxTests: XCTestCase {
    func testConvertBBoxToPixels_1000x1000() {
        let box = BBox1000(ymin: 100, xmin: 200, ymax: 300, xmax: 400)
        let result = convertBBoxToPixels(box, imageWidth: 1000, imageHeight: 1000)

        XCTAssertEqual(result.x, 200)
        XCTAssertEqual(result.y, 100)
        XCTAssertEqual(result.width, 200)
        XCTAssertEqual(result.height, 200)
    }

    func testConvertBBoxToPixels_scalesCorrectly() {
        let box = BBox1000(ymin: 0, xmin: 0, ymax: 500, xmax: 1000)
        let result = convertBBoxToPixels(box, imageWidth: 1440, imageHeight: 1024)

        XCTAssertEqual(result.x, 0)
        XCTAssertEqual(result.y, 0)
        XCTAssertEqual(result.width, 1440)
        XCTAssertEqual(result.height, 512)
    }

    func testConvertBBoxToPixels_roundsCorrectly() {
        let box = BBox1000(ymin: 333, xmin: 333, ymax: 667, xmax: 667)
        let result = convertBBoxToPixels(box, imageWidth: 1000, imageHeight: 1000)

        XCTAssertEqual(result.x, 333)
        XCTAssertEqual(result.y, 333)
        XCTAssertEqual(result.width, 334)
        XCTAssertEqual(result.height, 334)
    }
}
