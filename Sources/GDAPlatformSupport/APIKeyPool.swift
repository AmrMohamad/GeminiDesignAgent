import Foundation
import GeminiDesignAgentCore

public struct APIKeyPoolEntry: Codable, Equatable, Sendable {
    public let id: String
    public var label: String
    public var priority: Int
    public var exhaustedUntil: Date?

    public init(id: String, label: String, priority: Int, exhaustedUntil: Date? = nil) {
        self.id = id
        self.label = label
        self.priority = priority
        self.exhaustedUntil = exhaustedUntil
    }

    public var isExhausted: Bool {
        guard let exhaustedUntil else { return false }
        return exhaustedUntil > Date()
    }
}

public struct APIKeyPoolRegistry: Codable, Equatable, Sendable {
    public var entries: [APIKeyPoolEntry]

    public init(entries: [APIKeyPoolEntry] = []) {
        self.entries = entries
    }
}

public struct APIKeyPoolStatus: Equatable, Sendable {
    public let configuredCount: Int
    public let healthyCount: Int
    public let exhaustedCount: Int
    public let activeLabel: String?
    public let earliestRecovery: Date?

    public init(configuredCount: Int, healthyCount: Int, exhaustedCount: Int, activeLabel: String?, earliestRecovery: Date?) {
        self.configuredCount = configuredCount
        self.healthyCount = healthyCount
        self.exhaustedCount = exhaustedCount
        self.activeLabel = activeLabel
        self.earliestRecovery = earliestRecovery
    }
}

public struct APIKeyPoolSelection: Sendable {
    public let entry: APIKeyPoolEntry
    public let key: String

    public init(entry: APIKeyPoolEntry, key: String) {
        self.entry = entry
        self.key = key
    }
}

public protocol APIKeyPoolStore {
    var persistenceDescription: String { get }
    func loadRegistry() throws -> APIKeyPoolRegistry
    func saveRegistry(_ registry: APIKeyPoolRegistry) throws
    func loadKey(slot: String) throws -> String?
    func saveKey(_ key: String, slot: String) throws
    func deleteKey(slot: String) throws
}

public struct PlatformAPIKeyPoolStore: APIKeyPoolStore {
    public let persistenceDescription: String

    public init() {
        persistenceDescription = KeychainAPIKeyStore().persistenceDescription
    }

    public func loadRegistry() throws -> APIKeyPoolRegistry {
        let registryStore = KeychainAPIKeyStore(slot: "pool-registry")
        guard let encoded = try registryStore.load(), let data = encoded.data(using: .utf8) else {
            let legacyStore = KeychainAPIKeyStore()
            guard try legacyStore.load() != nil else { return APIKeyPoolRegistry() }
            return APIKeyPoolRegistry(entries: [APIKeyPoolEntry(id: "primary", label: "Primary", priority: 0)])
        }
        do {
            return try JSON.decoder.decode(APIKeyPoolRegistry.self, from: data)
        } catch {
            throw APIKeyStoreError.credentialStore("Credential pool metadata is invalid")
        }
    }

    public func saveRegistry(_ registry: APIKeyPoolRegistry) throws {
        let data = try JSON.encoder.encode(registry)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw APIKeyStoreError.invalidEncoding
        }
        try KeychainAPIKeyStore(slot: "pool-registry").save(encoded)
    }

    public func loadKey(slot: String) throws -> String? {
        try KeychainAPIKeyStore(slot: slot).load()
    }

    public func saveKey(_ key: String, slot: String) throws {
        try KeychainAPIKeyStore(slot: slot).save(key)
    }

    public func deleteKey(slot: String) throws {
        try KeychainAPIKeyStore(slot: slot).delete()
    }
}

public struct APIKeyPoolCoordinator {
    public let store: any APIKeyPoolStore
    public let now: @Sendable () -> Date

    public init(store: any APIKeyPoolStore = PlatformAPIKeyPoolStore(), now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    public static func nextPacificMidnight(after date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
        let startOfDay = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? date.addingTimeInterval(24 * 60 * 60)
    }

    public func status() throws -> APIKeyPoolStatus {
        let registry = try store.loadRegistry()
        let current = now()
        let availableEntries = registry.entries.filter { entry in
            (try? store.loadKey(slot: entry.id)) != nil
        }
        let active = try select(from: APIKeyPoolRegistry(entries: availableEntries), now: current)
        let exhausted = availableEntries.filter { entry in
            guard let until = entry.exhaustedUntil else { return false }
            return until > current
        }
        return APIKeyPoolStatus(
            configuredCount: availableEntries.count,
            healthyCount: availableEntries.count - exhausted.count,
            exhaustedCount: exhausted.count,
            activeLabel: active?.entry.label,
            earliestRecovery: exhausted.compactMap(\.exhaustedUntil).min()
        )
    }

    public func select(excluding excludedID: String? = nil) throws -> APIKeyPoolSelection? {
        let registry = try store.loadRegistry()
        return try select(from: registry, now: now(), excluding: excludedID)
    }

    /// Returns the user-selected (highest-priority) key without interpreting a
    /// prior quota observation as permission to switch projects automatically.
    public func selectPreferred() throws -> APIKeyPoolSelection? {
        let registry = try store.loadRegistry()
        for entry in registry.entries.sorted(by: { $0.priority < $1.priority }) {
            if let key = try store.loadKey(slot: entry.id) {
                return APIKeyPoolSelection(entry: entry, key: key)
            }
        }
        return nil
    }

    public func add(key: String, label: String) throws -> APIKeyPoolEntry {
        let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLabel.isEmpty,
              normalizedLabel.count <= 80,
              normalizedLabel.utf8.allSatisfy({ $0 >= 0x20 && $0 != 0x7F }) else {
            throw APIKeyStoreError.unavailable("Pool label must be 1-80 characters without control or newline characters")
        }

        var registry = try store.loadRegistry()
        let id = UUID().uuidString.lowercased()
        let entry = APIKeyPoolEntry(id: id, label: normalizedLabel, priority: registry.entries.count)
        try store.saveKey(key, slot: id)
        registry.entries.append(entry)
        do {
            try store.saveRegistry(registry)
        } catch {
            try? store.deleteKey(slot: id)
            throw error
        }
        return entry
    }

    public func savePrimary(key: String) throws {
        var registry = try store.loadRegistry()
        let previousKey = try store.loadKey(slot: "primary")
        try store.saveKey(key, slot: "primary")
        if !registry.entries.contains(where: { $0.id == "primary" }) {
            registry.entries.insert(APIKeyPoolEntry(id: "primary", label: "Primary", priority: 0), at: 0)
        }
        registry.entries = registry.entries.enumerated().map { index, entry in
            var updated = entry
            updated.priority = index
            return updated
        }
        do {
            try store.saveRegistry(registry)
        } catch {
            if let previousKey {
                try? store.saveKey(previousKey, slot: "primary")
            } else {
                try? store.deleteKey(slot: "primary")
            }
            throw error
        }
    }

    public func deletePrimary() throws {
        var registry = try store.loadRegistry()
        let previousKey = try store.loadKey(slot: "primary")
        try store.deleteKey(slot: "primary")
        registry.entries.removeAll { $0.id == "primary" }
        registry.entries = registry.entries.enumerated().map { index, entry in
            var updated = entry
            updated.priority = index
            return updated
        }
        do {
            try store.saveRegistry(registry)
        } catch {
            if let previousKey { try? store.saveKey(previousKey, slot: "primary") }
            throw error
        }
    }

    public func promote(id: String) throws {
        try validateID(id)
        var registry = try store.loadRegistry()
        guard registry.entries.contains(where: { $0.id == id }) else { throw APIKeyStoreError.unavailable("Credential pool entry not found") }
        registry.entries = registry.entries.sorted { lhs, rhs in
            if lhs.id == id { return true }
            if rhs.id == id { return false }
            return lhs.priority < rhs.priority
        }.enumerated().map { index, entry in
            var updated = entry
            updated.priority = index
            return updated
        }
        try store.saveRegistry(registry)
    }

    public func remove(id: String) throws {
        try validateID(id)
        var registry = try store.loadRegistry()
        guard registry.entries.contains(where: { $0.id == id }) else { throw APIKeyStoreError.unavailable("Credential pool entry not found") }
        let previousKey = try store.loadKey(slot: id)
        try store.deleteKey(slot: id)
        registry.entries.removeAll { $0.id == id }
        registry.entries = registry.entries.enumerated().map { index, entry in
            var updated = entry
            updated.priority = index
            return updated
        }
        do {
            try store.saveRegistry(registry)
        } catch {
            if let previousKey { try? store.saveKey(previousKey, slot: id) }
            throw error
        }
    }

    public func reset(id: String? = nil) throws {
        if let id { try validateID(id) }
        var registry = try store.loadRegistry()
        guard id == nil || registry.entries.contains(where: { $0.id == id }) else { throw APIKeyStoreError.unavailable("Credential pool entry not found") }
        for index in registry.entries.indices where id == nil || registry.entries[index].id == id {
            registry.entries[index].exhaustedUntil = nil
        }
        try store.saveRegistry(registry)
    }

    public func markQuotaExhausted(id: String, until: Date) throws {
        try validateID(id)
        var registry = try store.loadRegistry()
        guard let index = registry.entries.firstIndex(where: { $0.id == id }) else { return }
        registry.entries[index].exhaustedUntil = until
        try store.saveRegistry(registry)
    }

    private func select(from registry: APIKeyPoolRegistry, now: Date, excluding excludedID: String? = nil) throws -> APIKeyPoolSelection? {
        let candidates = registry.entries
            .filter { $0.id != excludedID }
            .filter { entry in
                guard let until = entry.exhaustedUntil else { return true }
                return until <= now
            }
            .sorted { $0.priority < $1.priority }

        for entry in candidates {
            if let key = try store.loadKey(slot: entry.id) {
                return APIKeyPoolSelection(entry: entry, key: key)
            }
        }
        return nil
    }

    private func validateID(_ id: String) throws {
        guard id.range(of: "^[A-Za-z0-9._-]{1,80}$", options: .regularExpression) != nil else {
            throw APIKeyStoreError.unavailable("Invalid credential pool entry ID")
        }
    }
}
