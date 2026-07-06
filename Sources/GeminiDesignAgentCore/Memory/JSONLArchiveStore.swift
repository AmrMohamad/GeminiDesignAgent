import Foundation

public final class JSONLArchiveStore: @unchecked Sendable {
    private let recordsDir: URL
    private let fm = FileManager.default

    public init(recordsDir: URL) {
        self.recordsDir = recordsDir
    }

    public func append<T: Encodable>(_ value: T, date: Date = Date()) async throws {
        let f = ISO8601DateFormatter()
        let dayStr = String(f.string(from: date).prefix(10))
        let fileURL = recordsDir.appendingPathComponent("\(dayStr).jsonl")

        let line = try JSON.compactEncoder.encode(value)
        guard let lineStr = String(data: line, encoding: .utf8) else {
            throw JSONLArchiveError.encodeFailed
        }

        let entry = lineStr + "\n"
        if fm.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            handle.seekToEndOfFile()
            if let data = entry.data(using: .utf8) {
                handle.write(data)
            }
            try handle.close()
        } else {
            try entry.data(using: .utf8)?.write(to: fileURL)
        }
    }

    public enum JSONLArchiveError: Error {
        case encodeFailed
        case writeFailed
    }
}
