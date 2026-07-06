import Foundation

public struct ImageInfo: Sendable {
    public let width: Int
    public let height: Int
    public let mimeType: String
    public let fileSize: Int
    public let format: ImageFormat

    public enum ImageFormat: String, Sendable {
        case png
        case jpeg
        case unknown
    }
}

public enum ImageInfoReader {
    public static func read(_ url: URL) throws -> ImageInfo {
        let fileSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        guard let header = try? handle.read(upToCount: 8192) else {
            throw ImageError.cannotReadHeader
        }

        let mimeType = MimeTypeDetector.detect(from: Array(header))

        guard let format = ImageInfo.ImageFormat(rawValue: mimeType.replacingOccurrences(of: "image/", with: "")) else {
            throw ImageError.unsupportedFormat(mimeType)
        }

        let (width, height) = try readDimensions(Data(header), format: format)

        return ImageInfo(
            width: width,
            height: height,
            mimeType: mimeType,
            fileSize: fileSize,
            format: format
        )
    }

    private static func readDimensions(_ data: Data, format: ImageInfo.ImageFormat) throws -> (Int, Int) {
        switch format {
        case .png:
            return try readPNGDimensions(data)
        case .jpeg:
            return try readJPEGDimensions(data)
        case .unknown:
            throw ImageError.unsupportedFormat("unknown")
        }
    }

    private static func readPNGDimensions(_ data: Data) throws -> (Int, Int) {
        guard data.count >= 24 else { throw ImageError.cannotReadDimensions }
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        let headerBytes = [UInt8](data.prefix(8))
        guard headerBytes == signature else { throw ImageError.invalidSignature }

        let width = Int(UInt32(bigEndian: data.subdata(in: 16..<20).withUnsafeBytes { $0.load(as: UInt32.self) }))
        let height = Int(UInt32(bigEndian: data.subdata(in: 20..<24).withUnsafeBytes { $0.load(as: UInt32.self) }))

        return (width, height)
    }

    private static func readJPEGDimensions(_ data: Data) throws -> (Int, Int) {
        guard data.count >= 4, data[0] == 0xFF, data[1] == 0xD8 else {
            throw ImageError.invalidSignature
        }

        var offset = 2
        while offset < data.count - 4 {
            guard data[offset] == 0xFF else {
                offset += 1
                continue
            }
            let marker = data[offset + 1]

            if marker == 0xC0 || marker == 0xC1 || marker == 0xC2 {
                if offset + 9 <= data.count {
                    let height = Int(UInt16(bigEndian: data.subdata(in: (offset + 5)..<(offset + 7)).withUnsafeBytes { $0.load(as: UInt16.self) }))
                    let width = Int(UInt16(bigEndian: data.subdata(in: (offset + 7)..<(offset + 9)).withUnsafeBytes { $0.load(as: UInt16.self) }))
                    return (width, height)
                }
                break
            }

            if offset + 4 > data.count { break }
            let segmentLength = Int(UInt16(bigEndian: data.subdata(in: (offset + 2)..<(offset + 4)).withUnsafeBytes { $0.load(as: UInt16.self) }))
            offset += 2 + segmentLength
        }

        throw ImageError.cannotReadDimensions
    }

    public enum ImageError: Error, LocalizedError {
        case cannotReadHeader
        case unsupportedFormat(String)
        case invalidSignature
        case cannotReadDimensions

        public var errorDescription: String? {
            switch self {
            case .cannotReadHeader: "Cannot read image header"
            case .unsupportedFormat(let fmt): "Unsupported image format: \(fmt)"
            case .invalidSignature: "Invalid image signature"
            case .cannotReadDimensions: "Cannot read image dimensions"
            }
        }
    }
}
