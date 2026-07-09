import Foundation
import XCTest
@testable import GeminiDesignAgentCore

final class FileSystemLockTests: XCTestCase {
    func testAcquireWritesInspectableMetadataAndReleaseRemovesOwnedLock() async throws {
        let dir = try temporaryDirectory()
        let lockURL = dir.appendingPathComponent("test.lock")
        let lock = try await FileSystemLock.acquire(lockDirectory: lockURL, timeoutSeconds: 0, purpose: "unit-test")

        let inspection = FileSystemLock.inspect(lockURL)
        XCTAssertEqual(inspection.state, .valid)
        XCTAssertEqual(inspection.metadata?.purpose, "unit-test")
        XCTAssertEqual(inspection.metadata?.lockID, lock.metadata.lockID)

        lock.release()
        XCTAssertEqual(FileSystemLock.inspect(lockURL).state, .absent)
    }

    func testAcquireFailsWhenAlreadyLockedAndReportsMetadata() async throws {
        let dir = try temporaryDirectory()
        let lockURL = dir.appendingPathComponent("test.lock")
        let lock = try await FileSystemLock.acquire(lockDirectory: lockURL, timeoutSeconds: 0, purpose: "first-lock")
        defer { lock.release() }

        do {
            _ = try await FileSystemLock.acquire(lockDirectory: lockURL, timeoutSeconds: 0, failIfLocked: true, purpose: "second-lock")
            XCTFail("Expected lock contention")
        } catch let FileSystemLockError.locked(_, inspection) {
            XCTAssertEqual(inspection.state, .valid)
            XCTAssertEqual(inspection.metadata?.purpose, "first-lock")
        }
    }

    func testMetadataWriteFailureCleansUpDirectoryAndAllowsRecovery() async throws {
        let dir = try temporaryDirectory()
        let lockURL = dir.appendingPathComponent("test.lock")

        do {
            _ = try await FileSystemLock.acquire(
                lockDirectory: lockURL,
                timeoutSeconds: 0,
                failIfLocked: false,
                purpose: "write-failure",
                fileManager: .default,
                metadataWriter: { _, _ in throw CocoaError(.fileWriteUnknown) }
            )
            XCTFail("Expected metadata write failure")
        } catch let FileSystemLockError.metadataWriteFailed(url, _) {
            XCTAssertEqual(url, lockURL)
        }

        XCTAssertEqual(FileSystemLock.inspect(lockURL).state, .absent)
        let recovered = try await FileSystemLock.acquire(lockDirectory: lockURL, timeoutSeconds: 0, purpose: "recovered")
        recovered.release()
    }

    func testReleaseCannotDeleteReplacementLock() async throws {
        let dir = try temporaryDirectory()
        let lockURL = dir.appendingPathComponent("test.lock")
        let original = try await FileSystemLock.acquire(lockDirectory: lockURL, timeoutSeconds: 0, purpose: "original")
        XCTAssertEqual(try FileSystemLock.forceClear(lockURL), .cleared)

        let replacement = try await FileSystemLock.acquire(lockDirectory: lockURL, timeoutSeconds: 0, purpose: "replacement")
        original.release()

        let inspection = FileSystemLock.inspect(lockURL)
        XCTAssertEqual(inspection.state, .valid)
        XCTAssertEqual(inspection.metadata?.lockID, replacement.metadata.lockID)
        replacement.release()
    }

    func testForceClearHandlesAbsentAndExistingLocks() async throws {
        let dir = try temporaryDirectory()
        let lockURL = dir.appendingPathComponent("test.lock")
        XCTAssertEqual(try FileSystemLock.forceClear(lockURL), .alreadyAbsent)

        _ = try await FileSystemLock.acquire(lockDirectory: lockURL, timeoutSeconds: 0, purpose: "clear-me")
        XCTAssertEqual(try FileSystemLock.forceClear(lockURL), .cleared)
        XCTAssertEqual(FileSystemLock.inspect(lockURL).state, .absent)
    }

    func testCancellationDuringLockWaitStopsWithoutTakingLock() async throws {
        let dir = try temporaryDirectory()
        let lockURL = dir.appendingPathComponent("test.lock")
        let holder = try await FileSystemLock.acquire(lockDirectory: lockURL, timeoutSeconds: 0, purpose: "holder")
        defer { holder.release() }

        let waiter = Task { () -> Error? in
            do {
                _ = try await FileSystemLock.acquire(lockDirectory: lockURL, timeoutSeconds: 30, purpose: "waiter")
                return nil
            } catch {
                return error
            }
        }
        try await Task.sleep(for: .milliseconds(25))
        waiter.cancel()

        let error = await waiter.value
        XCTAssertTrue(error is CancellationError)
        XCTAssertEqual(FileSystemLock.inspect(lockURL).metadata?.lockID, holder.metadata.lockID)
    }

    func testJSONLArchiveAppendUsesLockAndWritesAllEntries() async throws {
        let dir = try temporaryDirectory()
        let archive = JSONLArchiveStore(recordsDir: dir)
        let date = ISO8601DateFormatter().date(from: "2026-07-09T00:00:00Z")!

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    try await archive.append(["index": index], date: date)
                }
            }
            try await group.waitForAll()
        }

        let file = dir.appendingPathComponent("2026-07-09.jsonl")
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 8)
    }

    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gda-lock-tests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
