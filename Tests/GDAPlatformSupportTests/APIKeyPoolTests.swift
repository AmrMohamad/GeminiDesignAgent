import XCTest
@testable import GDAPlatformSupport

final class APIKeyPoolTests: XCTestCase {
    func testSelectionReturnsHighestPriorityHealthyKeyWithoutExposingRegistrySecrets() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let store = InMemoryPoolStore(
            registry: APIKeyPoolRegistry(entries: [
                APIKeyPoolEntry(id: "primary", label: "Primary", priority: 0, exhaustedUntil: now.addingTimeInterval(60)),
                APIKeyPoolEntry(id: "fallback", label: "Fallback", priority: 1)
            ]),
            keys: ["primary": "secret-primary", "fallback": "secret-fallback"]
        )

        let selection = try APIKeyPoolCoordinator(store: store, now: { now }).select()
        XCTAssertEqual(selection?.entry.id, "fallback")
        XCTAssertEqual(selection?.key, "secret-fallback")
        let encodedRegistry = try JSONEncoder().encode(try store.loadRegistry())
        let registryText = String(decoding: encodedRegistry, as: UTF8.self)
        XCTAssertFalse(registryText.contains("secret-primary"))
        XCTAssertFalse(registryText.contains("secret-fallback"))
    }

    func testQuotaExhaustionMarksOnlySelectedEntryUntilReset() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let store = InMemoryPoolStore(
            registry: APIKeyPoolRegistry(entries: [
                APIKeyPoolEntry(id: "primary", label: "Primary", priority: 0),
                APIKeyPoolEntry(id: "fallback", label: "Fallback", priority: 1)
            ]),
            keys: ["primary": "key-1", "fallback": "key-2"]
        )
        let coordinator = APIKeyPoolCoordinator(store: store, now: { now })

        try coordinator.markQuotaExhausted(id: "primary", until: now.addingTimeInterval(60))
        XCTAssertEqual(try coordinator.select()?.entry.id, "fallback")
        XCTAssertEqual(try coordinator.status().exhaustedCount, 1)

        try coordinator.reset(id: "primary")
        XCTAssertEqual(try coordinator.select()?.entry.id, "primary")
        XCTAssertEqual(try coordinator.status().exhaustedCount, 0)
    }

    func testPromotionReordersEntriesAndRemovalDeletesSecureSlot() throws {
        let store = InMemoryPoolStore(
            registry: APIKeyPoolRegistry(entries: [
                APIKeyPoolEntry(id: "one", label: "One", priority: 0),
                APIKeyPoolEntry(id: "two", label: "Two", priority: 1)
            ]),
            keys: ["one": "key-1", "two": "key-2"]
        )
        let coordinator = APIKeyPoolCoordinator(store: store)

        try coordinator.promote(id: "two")
        XCTAssertEqual(try coordinator.select()?.entry.id, "two")
        try coordinator.remove(id: "two")
        XCTAssertNil(store.keys["two"])
        XCTAssertEqual(try coordinator.select()?.entry.id, "one")
    }

    func testLegacyPrimaryCanBeSavedWithoutCreatingASecondSecretSlot() throws {
        let store = InMemoryPoolStore(registry: APIKeyPoolRegistry(), keys: ["primary": "old-key"])
        let coordinator = APIKeyPoolCoordinator(store: store)

        try coordinator.savePrimary(key: "new-key")
        XCTAssertEqual(store.keys["primary"], "new-key")
        XCTAssertEqual(try coordinator.select()?.entry.id, "primary")
        XCTAssertEqual(try coordinator.status().configuredCount, 1)
    }

    func testPoolRejectsControlCharactersInLabelsBeforePersistingSecret() {
        let store = InMemoryPoolStore(registry: APIKeyPoolRegistry(), keys: [:])
        let coordinator = APIKeyPoolCoordinator(store: store)

        XCTAssertThrowsError(try coordinator.add(key: "secret", label: "project\nprimary"))
        XCTAssertTrue(store.keys.isEmpty)
        XCTAssertTrue(store.registry.entries.isEmpty)
    }

    func testNextPacificMidnightIsStableAcrossLocalTimezone() {
        let date = Date(timeIntervalSince1970: 1_752_052_800) // 2025-07-15T00:00:00Z
        let next = APIKeyPoolCoordinator.nextPacificMidnight(after: date)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertEqual(calendar.component(.hour, from: next), 0)
        XCTAssertEqual(calendar.component(.minute, from: next), 0)
        XCTAssertEqual(calendar.component(.second, from: next), 0)
        XCTAssertGreaterThan(next, date)
    }
}

private final class InMemoryPoolStore: APIKeyPoolStore, @unchecked Sendable {
    let persistenceDescription = "test secure store"
    var registry: APIKeyPoolRegistry
    var keys: [String: String]

    init(registry: APIKeyPoolRegistry, keys: [String: String]) {
        self.registry = registry
        self.keys = keys
    }

    func loadRegistry() throws -> APIKeyPoolRegistry { registry }
    func saveRegistry(_ registry: APIKeyPoolRegistry) throws { self.registry = registry }
    func loadKey(slot: String) throws -> String? { keys[slot] }
    func saveKey(_ key: String, slot: String) throws { keys[slot] = key }
    func deleteKey(slot: String) throws { keys.removeValue(forKey: slot) }
}
