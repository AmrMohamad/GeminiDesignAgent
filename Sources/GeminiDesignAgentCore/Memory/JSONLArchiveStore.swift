import Foundation

#if os(Linux)
import Glibc
#else
import Darwin
#endif

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
        try fm.createDirectory(at: recordsDir, withIntermediateDirectories: true)
        let lockFD = open(recordsDir.appendingPathComponent(".records.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockFD >= 0 else {
            throw JSONLArchiveError.lockFailed
        }
        defer {
            _ = flock(lockFD, LOCK_UN)
            close(lockFD)
        }
        guard flock(lockFD, LOCK_EX) == 0 else {
            throw JSONLArchiveError.lockFailed
        }

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
        case lockFailed
    }
}
