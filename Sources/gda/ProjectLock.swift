import Foundation
import GeminiDesignAgentCore

final class ProjectLock {
    private let lock: FileSystemLock

    private init(lock: FileSystemLock) {
        self.lock = lock
    }

    static func acquire(projectDir: URL, timeoutSeconds: Int, failIfLocked: Bool) async throws -> ProjectLock {
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let lockURL = ArtifactPaths(projectDir: projectDir).projectLockDir
        do {
            let lock = try await FileSystemLock.acquire(
                lockDirectory: lockURL,
                timeoutSeconds: timeoutSeconds,
                failIfLocked: failIfLocked,
                purpose: "gda-project"
            )
            return ProjectLock(lock: lock)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as FileSystemLockError {
            throw CLIError(
                code: "PROJECT_LOCKED",
                title: "Project is locked by another gda process",
                message: error.localizedDescription,
                resolution: "Wait for the other run to finish, retry with a larger `--lock-timeout`, or use `--fail-if-locked` in CI to fail immediately.",
                retryable: true,
                exitCode: 10
            )
        } catch {
            throw CLIError(
                code: "PROJECT_LOCK_ERROR",
                title: "Could not open project lock",
                message: "Could not open lock file: \(lockURL.path)",
                resolution: "Check project directory permissions and retry.",
                retryable: true,
                exitCode: 10
            )
        }
    }

    func release() {
        lock.release()
    }
}
