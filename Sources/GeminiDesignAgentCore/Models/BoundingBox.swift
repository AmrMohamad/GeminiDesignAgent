import Foundation

public struct BBox1000: Codable, Sendable {
    public var ymin: Int
    public var xmin: Int
    public var ymax: Int
    public var xmax: Int
    public var confidence: Double

    public init(ymin: Int, xmin: Int, ymax: Int, xmax: Int, confidence: Double = 1.0) {
        self.ymin = ymin
        self.xmin = xmin
        self.ymax = ymax
        self.xmax = xmax
        self.confidence = confidence
    }
}

public struct BBoxPx: Codable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public func convertBBoxToPixels(_ box: BBox1000, imageWidth: Int, imageHeight: Int) -> BBoxPx {
    let x1 = Int((Double(box.xmin) / 1000.0 * Double(imageWidth)).rounded())
    let y1 = Int((Double(box.ymin) / 1000.0 * Double(imageHeight)).rounded())
    let x2 = Int((Double(box.xmax) / 1000.0 * Double(imageWidth)).rounded())
    let y2 = Int((Double(box.ymax) / 1000.0 * Double(imageHeight)).rounded())

    return BBoxPx(
        x: x1,
        y: y1,
        width: max(0, x2 - x1),
        height: max(0, y2 - y1)
    )
}
