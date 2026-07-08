import Foundation

#if os(Linux)
import Glibc
#else
import Darwin
#endif

final class ProjectLock {
    private let fd: Int32
    private let lockURL: URL

    private init(fd: Int32, lockURL: URL) {
        self.fd = fd
        self.lockURL = lockURL
    }

    static func acquire(projectDir: URL, timeoutSeconds: Int, failIfLocked: Bool) throws -> ProjectLock {
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let lockURL = projectDir.appendingPathComponent("lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw CLIError(
                code: "PROJECT_LOCK_ERROR",
                title: "Could not open project lock",
                message: "Could not open lock file: \(lockURL.path)",
                resolution: "Check project directory permissions and retry.",
                retryable: true,
                exitCode: 10
            )
        }

        let deadline = Date().addingTimeInterval(TimeInterval(max(0, timeoutSeconds)))
        repeat {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                let lock = ProjectLock(fd: fd, lockURL: lockURL)
                try lock.writeMetadata()
                return lock
            }

            if failIfLocked || Date() >= deadline {
                let metadata = (try? String(contentsOf: lockURL, encoding: .utf8)) ?? ""
                close(fd)
                throw CLIError(
                    code: "PROJECT_LOCKED",
                    title: "Project is locked by another gda process",
                    message: "Could not acquire project lock at \(lockURL.path). \(metadataPrefix(metadata))",
                    resolution: "Wait for the other run to finish, retry with a larger `--lock-timeout`, or use `--fail-if-locked` in CI to fail immediately.",
                    retryable: true,
                    exitCode: 10
                )
            }

            Thread.sleep(forTimeInterval: 0.1)
        } while true
    }

    func release() {
        _ = flock(fd, LOCK_UN)
        close(fd)
    }

    private func writeMetadata() throws {
        let metadata: [String: Any] = [
            "pid": Int(getpid()),
            "acquired_at": ISO8601DateFormatter().string(from: Date())
        ]
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        _ = ftruncate(fd, 0)
        _ = lseek(fd, 0, SEEK_SET)
        _ = data.withUnsafeBytes { buffer in
            write(fd, buffer.baseAddress, buffer.count)
        }
    }

    private static func metadataPrefix(_ metadata: String) -> String {
        let trimmed = metadata.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return "Current lock metadata: \(trimmed.prefix(300))"
    }
}
