import Foundation

public struct FileSystemLockMetadata: Codable, Sendable {
    public var lockID: String?
    public var pid: Int32
    public var host: String
    public var acquiredAt: Date
    public var purpose: String

    public init(
        lockID: String = UUID().uuidString,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        host: String = ProcessInfo.processInfo.hostName,
        acquiredAt: Date = Date(),
        purpose: String
    ) {
        self.lockID = lockID
        self.pid = pid
        self.host = host
        self.acquiredAt = acquiredAt
        self.purpose = purpose
    }

    enum CodingKeys: String, CodingKey {
        case lockID = "lock_id"
        case pid
        case host
        case acquiredAt = "acquired_at"
        case purpose
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lockID = try container.decodeIfPresent(String.self, forKey: .lockID)
        pid = try container.decode(Int32.self, forKey: .pid)
        host = try container.decode(String.self, forKey: .host)
        acquiredAt = try container.decode(Date.self, forKey: .acquiredAt)
        purpose = try container.decode(String.self, forKey: .purpose)
    }
}

public struct FileSystemLockInspection: Sendable {
    public enum State: String, Sendable, Equatable {
        case absent
        case valid
        case missingMetadata
        case invalidMetadata
        case legacy
    }

    public let lockDirectory: URL
    public let state: State
    public let metadata: FileSystemLockMetadata?
    public let detail: String?

    public var isPresent: Bool {
        state != .absent
    }
}

public enum FileSystemLockClearResult: String, Sendable, Equatable {
    case cleared
    case alreadyAbsent
}

public final class FileSystemLock: @unchecked Sendable {
    public let lockDirectory: URL
    public let metadata: FileSystemLockMetadata
    private let fm: FileManager

    private init(lockDirectory: URL, metadata: FileSystemLockMetadata, fileManager: FileManager) {
        self.lockDirectory = lockDirectory
        self.metadata = metadata
        self.fm = fileManager
    }

    public static func acquire(
        lockDirectory: URL,
        timeoutSeconds: Int,
        failIfLocked: Bool = false,
        purpose: String,
        fileManager: FileManager = .default
    ) async throws -> FileSystemLock {
        try await acquire(
            lockDirectory: lockDirectory,
            timeoutSeconds: timeoutSeconds,
            failIfLocked: failIfLocked,
            purpose: purpose,
            fileManager: fileManager,
            metadataWriter: { data, url in
                try data.write(to: url, options: [.atomic])
            }
        )
    }

    static func acquire(
        lockDirectory: URL,
        timeoutSeconds: Int,
        failIfLocked: Bool,
        purpose: String,
        fileManager: FileManager,
        metadataWriter: @escaping @Sendable (Data, URL) throws -> Void
    ) async throws -> FileSystemLock {
        let metadata = FileSystemLockMetadata(purpose: purpose)
        let metadataData = try JSON.encoder.encode(metadata)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(max(0, timeoutSeconds)))

        while true {
            try Task.checkCancellation()
            do {
                try fileManager.createDirectory(at: lockDirectory, withIntermediateDirectories: false)
            } catch {
                guard fileManager.fileExists(atPath: lockDirectory.path) else {
                    throw FileSystemLockError.acquireFailed(lockDirectory, error.localizedDescription)
                }

                if failIfLocked || clock.now >= deadline {
                    throw FileSystemLockError.locked(lockDirectory, inspect(lockDirectory, fileManager: fileManager))
                }
                try await Task.sleep(for: .milliseconds(100))
                continue
            }

            let lock = FileSystemLock(lockDirectory: lockDirectory, metadata: metadata, fileManager: fileManager)
            do {
                try metadataWriter(metadataData, lock.metadataURL)
                return lock
            } catch {
                try? fileManager.removeItem(at: lockDirectory)
                throw FileSystemLockError.metadataWriteFailed(lockDirectory, error.localizedDescription)
            }
        }
    }

    public func release() {
        let inspection = Self.inspect(lockDirectory, fileManager: fm)
        guard case .valid = inspection.state,
              inspection.metadata?.lockID == metadata.lockID else {
            return
        }
        try? fm.removeItem(at: lockDirectory)
    }

    public static func inspect(_ lockDirectory: URL, fileManager: FileManager = .default) -> FileSystemLockInspection {
        guard fileManager.fileExists(atPath: lockDirectory.path) else {
            return FileSystemLockInspection(lockDirectory: lockDirectory, state: .absent, metadata: nil, detail: nil)
        }

        let metadataURL = lockDirectory.appendingPathComponent("metadata.json")
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            return FileSystemLockInspection(lockDirectory: lockDirectory, state: .missingMetadata, metadata: nil, detail: "metadata.json is missing")
        }

        do {
            let data = try Data(contentsOf: metadataURL)
            let metadata = try JSON.decoder.decode(FileSystemLockMetadata.self, from: data)
            let state: FileSystemLockInspection.State = metadata.lockID == nil ? .legacy : .valid
            return FileSystemLockInspection(lockDirectory: lockDirectory, state: state, metadata: metadata, detail: nil)
        } catch {
            return FileSystemLockInspection(lockDirectory: lockDirectory, state: .invalidMetadata, metadata: nil, detail: error.localizedDescription)
        }
    }

    public static func forceClear(_ lockDirectory: URL, fileManager: FileManager = .default) throws -> FileSystemLockClearResult {
        guard fileManager.fileExists(atPath: lockDirectory.path) else {
            return .alreadyAbsent
        }

        let quarantineURL = lockDirectory
            .deletingLastPathComponent()
            .appendingPathComponent(".\(lockDirectory.lastPathComponent).clearing-\(UUID().uuidString)")
        do {
            try fileManager.moveItem(at: lockDirectory, to: quarantineURL)
        } catch {
            if !fileManager.fileExists(atPath: lockDirectory.path) {
                return .alreadyAbsent
            }
            throw FileSystemLockError.clearFailed(lockDirectory, error.localizedDescription)
        }

        do {
            try fileManager.removeItem(at: quarantineURL)
            return .cleared
        } catch {
            throw FileSystemLockError.clearFailed(quarantineURL, error.localizedDescription)
        }
    }

    private var metadataURL: URL {
        lockDirectory.appendingPathComponent("metadata.json")
    }
}

public enum FileSystemLockError: Error, LocalizedError {
    case locked(URL, FileSystemLockInspection)
    case acquireFailed(URL, String)
    case metadataWriteFailed(URL, String)
    case clearFailed(URL, String)

    public var errorDescription: String? {
        switch self {
        case .locked(let url, let inspection):
            let detail = inspection.detail ?? inspection.metadata.map { "pid=\($0.pid), host=\($0.host), purpose=\($0.purpose)" }
            return detail.map { "Could not acquire lock at \(url.path). \($0)" } ?? "Could not acquire lock at \(url.path)."
        case .acquireFailed(let url, let details):
            return "Could not create lock at \(url.path): \(details)"
        case .metadataWriteFailed(let url, let details):
            return "Could not write lock metadata at \(url.path): \(details)"
        case .clearFailed(let url, let details):
            return "Could not clear lock at \(url.path): \(details)"
        }
    }
}
