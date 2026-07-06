import Foundation

public enum MimeTypeDetector {
    public static func detect(from bytes: [UInt8]) -> String {
        guard bytes.count >= 8 else { return "application/octet-stream" }

        let pngSig: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        if Array(bytes.prefix(8)) == pngSig {
            return "image/png"
        }

        if bytes.count >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8 {
            return "image/jpeg"
        }

        if bytes.count >= 12
            && bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46
            && bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50 {
            return "image/webp"
        }

        return "application/octet-stream"
    }

    public static func detect(from url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        default: return nil
        }
    }

    public static func isSupportedImage(_ mimeType: String) -> Bool {
        ["image/png", "image/jpeg"].contains(mimeType)
    }
}
