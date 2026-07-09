import XCTest
@testable import GeminiDesignAgentCore

final class MimeTypeDetectorTests: XCTestCase {
    func testDetectPNG() {
        let bytes: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 0]
        XCTAssertEqual(MimeTypeDetector.detect(from: bytes), "image/png")
    }

    func testDetectJPEG() {
        let bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0, 0, 0, 0, 0]
        XCTAssertEqual(MimeTypeDetector.detect(from: bytes), "image/jpeg")
    }

    func testDetectWEBP() {
        let bytes: [UInt8] = [
            0x52, 0x49, 0x46, 0x46,
            0, 0, 0, 0,
            0x57, 0x45, 0x42, 0x50
        ]
        XCTAssertEqual(MimeTypeDetector.detect(from: bytes), "image/webp")
    }

    func testDetectUnknown() {
        let bytes: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        XCTAssertEqual(MimeTypeDetector.detect(from: bytes), "application/octet-stream")
    }

    func testDetectFromURLExtension_png() {
        let url = URL(fileURLWithPath: "/path/to/image.png")
        XCTAssertEqual(MimeTypeDetector.detect(from: url), "image/png")
    }

    func testDetectFromURLExtension_jpg() {
        let url = URL(fileURLWithPath: "/path/to/image.jpg")
        XCTAssertEqual(MimeTypeDetector.detect(from: url), "image/jpeg")
    }

    func testDetectFromURLExtension_webpButUnsupported() {
        let url = URL(fileURLWithPath: "/path/to/image.webp")
        XCTAssertEqual(MimeTypeDetector.detect(from: url), "image/webp")
        XCTAssertFalse(MimeTypeDetector.isSupportedImage("image/webp"))
    }

    func testDetectFromURLExtension_gifIsNotAccepted() {
        let url = URL(fileURLWithPath: "/path/to/image.gif")
        XCTAssertNil(MimeTypeDetector.detect(from: url))
        XCTAssertFalse(MimeTypeDetector.isSupportedImage("image/gif"))
    }

    func testIsSupportedImage() {
        XCTAssertTrue(MimeTypeDetector.isSupportedImage("image/png"))
        XCTAssertTrue(MimeTypeDetector.isSupportedImage("image/jpeg"))
        XCTAssertFalse(MimeTypeDetector.isSupportedImage("image/webp"))
        XCTAssertFalse(MimeTypeDetector.isSupportedImage("image/gif"))
    }
}
