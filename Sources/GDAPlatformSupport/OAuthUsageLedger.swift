import Foundation
import GeminiDesignAgentCore

/// Locally observed activity only. It deliberately does not attempt to infer a
/// provider quota or remaining allowance.
public struct ObservedUsageEntry: Codable, Equatable, Sendable {
    public var profileID: String
    public var pacificDay: String
    public var model: String
    public var attempts: Int
    public var successes: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var totalTokens: Int
    public var lastError: String?
    public var cooldownUntil: Date?

    public init(
        profileID: String,
        pacificDay: String,
        model: String,
        attempts: Int = 0,
        successes: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        totalTokens: Int = 0,
        lastError: String? = nil,
        cooldownUntil: Date? = nil
    ) {
        self.profileID = profileID
        self.pacificDay = pacificDay
        self.model = model
        self.attempts = attempts
        self.successes = successes
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.lastError = lastError
        self.cooldownUntil = cooldownUntil
    }
}

public struct ObservedUsageLedger: Codable, Equatable, Sendable {
    public var version: Int
    public var entries: [ObservedUsageEntry]

    public init(version: Int = 1, entries: [ObservedUsageEntry] = []) {
        self.version = version
        self.entries = entries
    }
}

public struct OAuthUsageLedger: Sendable {
    private let homeDirectory: URL
    private let now: @Sendable () -> Date

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.homeDirectory = homeDirectory
        self.now = now
    }

    public func recordAttempt(profileID: String, model: String) async throws {
        try await update(profileID: profileID, model: model) { entry in
            entry.attempts += 1
        }
    }

    public func recordSuccess(profileID: String, model: String, usage: RunTokenUsage?) async throws {
        try await update(profileID: profileID, model: model) { entry in
            entry.successes += 1
            entry.inputTokens += max(0, usage?.inputTokens ?? 0)
            entry.outputTokens += max(0, usage?.outputTokens ?? 0)
            entry.totalTokens += max(0, usage?.totalTokens ?? 0)
            entry.lastError = nil
        }
    }

    public func recordFailure(
        profileID: String,
        model: String,
        errorCode: String,
        cooldownUntil: Date? = nil
    ) async throws {
        try await update(profileID: profileID, model: model) { entry in
            entry.lastError = errorCode
            if let cooldownUntil { entry.cooldownUntil = cooldownUntil }
        }
    }

    public func observedUsage(profileID: String? = nil) async throws -> [ObservedUsageEntry] {
        try await withLock {
            let ledger = try loadLedger()
            return ledger.entries
                .filter { profileID == nil || $0.profileID == profileID }
                .sorted {
                    if $0.pacificDay != $1.pacificDay { return $0.pacificDay > $1.pacificDay }
                    if $0.profileID != $1.profileID { return $0.profileID < $1.profileID }
                    return $0.model < $1.model
                }
        }
    }

    private var directoryURL: URL {
        homeDirectory.appendingPathComponent(".geminidesignagent", isDirectory: true)
    }

    private var ledgerURL: URL {
        directoryURL.appendingPathComponent("usage-v1.json")
    }

    private var lockDirectoryURL: URL {
        directoryURL.appendingPathComponent("usage-v1.lock", isDirectory: true)
    }

    private func update(
        profileID: String,
        model: String,
        mutate: (inout ObservedUsageEntry) -> Void
    ) async throws {
        guard profileID.range(of: "^[a-f0-9-]{36}$", options: .regularExpression) != nil,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OAuthError.credentialStoreUnavailable("Observed usage key is invalid")
        }
        try await withLock {
            var ledger = try loadLedger()
            let day = pacificDay(for: now())
            if let index = ledger.entries.firstIndex(where: {
                $0.profileID == profileID && $0.pacificDay == day && $0.model == model
            }) {
                mutate(&ledger.entries[index])
            } else {
                var entry = ObservedUsageEntry(profileID: profileID, pacificDay: day, model: model)
                mutate(&entry)
                ledger.entries.append(entry)
            }
            prune(&ledger, retainingDays: 32)
            try saveLedger(ledger)
        }
    }

    private func withLock<T>(_ body: () throws -> T) async throws -> T {
        try ensureDirectory()
        let lock = try await FileSystemLock.acquire(
            lockDirectory: lockDirectoryURL,
            timeoutSeconds: 30,
            purpose: "oauth-observed-usage"
        )
        defer { lock.release() }
        return try body()
    }

    private func loadLedger() throws -> ObservedUsageLedger {
        guard FileManager.default.fileExists(atPath: ledgerURL.path) else { return ObservedUsageLedger() }
        let data = try Data(contentsOf: ledgerURL)
        do {
            let ledger = try JSONDecoder().decode(ObservedUsageLedger.self, from: data)
            guard ledger.version == 1 else {
                throw OAuthError.credentialStoreUnavailable("Observed usage format is unsupported")
            }
            return ledger
        } catch let error as OAuthError {
            throw error
        } catch {
            throw OAuthError.credentialStoreUnavailable("Observed usage file is invalid")
        }
    }

    private func saveLedger(_ ledger: ObservedUsageLedger) throws {
        let data = try JSONEncoder().encode(ledger)
        try data.write(to: ledgerURL, options: .atomic)
        #if !os(Windows)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ledgerURL.path)
        #endif
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        #if !os(Windows)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        #endif
    }

    private func pacificDay(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/Los_Angeles")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func prune(_ ledger: inout ObservedUsageLedger, retainingDays: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
        let earliest = calendar.date(byAdding: .day, value: -(retainingDays - 1), to: calendar.startOfDay(for: now())) ?? now()
        let earliestDay = pacificDay(for: earliest)
        ledger.entries.removeAll { $0.pacificDay < earliestDay }
    }
}
