import Foundation

public struct RuntimeContext: Codable, Sendable {
    public var projectId: String
    public var projectName: String
    public var sessionId: String
    public var screenName: String?
    public var projectDir: String
    public var platform: String
    public var startedAt: Date

    public init(
        projectId: String,
        projectName: String = "",
        sessionId: String? = nil,
        screenName: String? = nil,
        projectDir: String,
        platform: String = "cli",
        startedAt: Date = Date()
    ) {
        self.projectId = projectId
        self.projectName = projectName
        self.sessionId = sessionId ?? StableID.run()
        self.screenName = screenName
        self.projectDir = projectDir
        self.platform = platform
        self.startedAt = startedAt
    }
}

public struct ArtifactPaths: Sendable {
    public let rootDir: URL
    public let recordsDir: URL
    public let refsDir: URL
    public let screensDir: URL
    public let profilesDir: URL
    public let artifactsDir: URL
    public let dbPath: URL
    public let configPath: URL

    public init(projectDir: URL) {
        rootDir = projectDir
        recordsDir = projectDir.appendingPathComponent("records")
        refsDir = projectDir.appendingPathComponent("refs")
        screensDir = projectDir.appendingPathComponent("screens")
        profilesDir = projectDir.appendingPathComponent("profiles")
        artifactsDir = projectDir.appendingPathComponent("artifacts")
        dbPath = projectDir.appendingPathComponent("memory.db")
        configPath = projectDir.appendingPathComponent("config.json")
    }

    public func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [rootDir, recordsDir, refsDir, screensDir, profilesDir, artifactsDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    public func artifactDir(runId: String) -> URL {
        artifactsDir.appendingPathComponent(runId)
    }

    public func refURL(evidenceId: String, date: Date = Date()) -> URL {
        let day = String(ISO8601DateFormatter().string(from: date).prefix(10)).split(separator: "-")
        guard day.count == 3 else {
            return refsDir.appendingPathComponent("\(evidenceId).json")
        }
        return refsDir
            .appendingPathComponent(String(day[0]))
            .appendingPathComponent(String(day[1]))
            .appendingPathComponent(String(day[2]))
            .appendingPathComponent("\(evidenceId).json")
    }
}
