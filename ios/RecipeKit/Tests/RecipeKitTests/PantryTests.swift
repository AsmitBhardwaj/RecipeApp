//
//  PantryTests.swift
//  RecipeKitTests
//
//  Kitchen (pantry) feature: local store CRUD, account scoping, the sync
//  round-trip through LocalSyncApplier (upsert / delete / apply-side LWW), and
//  that account deletion wipes pantry data.
//

import XCTest
@testable import RecipeKit

final class PantryTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "pantry-\(UUID().uuidString)")!
    }

    // MARK: - Store

    func testStoreUpsertRemoveAndOrder() {
        let store = PantryStore(defaults: freshDefaults(), userScope: "u1")
        let a = PantryItem(name: "Olive oil")
        let b = PantryItem(name: "Garlic")
        store.upsert(a)
        store.upsert(b)
        XCTAssertEqual(Set(store.all().map(\.id)), [a.id, b.id])

        // upsert with same id replaces (no duplicate).
        store.upsert(PantryItem(id: a.id, name: "Extra-virgin olive oil", dateAdded: a.dateAdded))
        XCTAssertEqual(store.all().count, 2)
        XCTAssertEqual(store.all().first { $0.id == a.id }?.name, "Extra-virgin olive oil")

        store.remove(id: a.id)
        XCTAssertEqual(store.all().map(\.id), [b.id])
    }

    func testStoreIsAccountScoped() {
        let d = freshDefaults()
        PantryStore(defaults: d, userScope: "alice").upsert(PantryItem(name: "Rice"))
        XCTAssertEqual(PantryStore(defaults: d, userScope: "alice").all().count, 1)
        XCTAssertEqual(PantryStore(defaults: d, userScope: "bob").all().count, 0)  // isolated
    }

    func testNameStoredVerbatim() {
        // No normalization at write time — casing/inner spacing preserved exactly.
        let store = PantryStore(defaults: freshDefaults(), userScope: "u1")
        store.upsert(PantryItem(name: "Extra-Virgin  Olive Oil"))
        XCTAssertEqual(store.all().first?.name, "Extra-Virgin  Olive Oil")
    }

    // MARK: - Payload codec

    func testPayloadRoundTrips() {
        // Pin dateAdded to a whole-second epoch so the `.secondsSince1970` Double
        // round-trip is bit-exact (same guard the meal-plan codec test uses).
        let item = PantryItem(id: UUID(), name: "Butter", dateAdded: Date(timeIntervalSince1970: 1_725_000_000))
        let payload = SyncCodec.encode(item)
        XCTAssertNotNil(payload)
        let decoded = SyncCodec.decode(PantryItem.self, from: payload)
        XCTAssertEqual(decoded, item)
    }

    // MARK: - Sync applier

    func testApplierUpsertsPantryItem() {
        let d = freshDefaults()
        let applier = LocalSyncApplier(userId: "u1", defaults: d)
        let item = PantryItem(name: "Spinach")
        applier.apply(SyncChange(
            collection: .pantryItems, itemId: item.id.uuidString,
            updatedAt: 100, payload: SyncCodec.encode(item)
        ))
        XCTAssertEqual(PantryStore(defaults: d, userScope: "u1").all().map(\.name), ["Spinach"])
    }

    func testApplierDeletesPantryItem() {
        let d = freshDefaults()
        let store = PantryStore(defaults: d, userScope: "u1")
        let item = PantryItem(name: "Eggs")
        store.upsert(item)
        let applier = LocalSyncApplier(userId: "u1", defaults: d)
        applier.apply(SyncChange(
            collection: .pantryItems, itemId: item.id.uuidString,
            updatedAt: 200, deleted: true, payload: nil
        ))
        XCTAssertTrue(store.all().isEmpty)
    }

    func testApplierIgnoresStaleChange() {
        let d = freshDefaults()
        let applier = LocalSyncApplier(userId: "u1", defaults: d)
        let item = PantryItem(name: "Milk")
        // Newer version applied first...
        applier.apply(SyncChange(collection: .pantryItems, itemId: item.id.uuidString,
                                 updatedAt: 300, payload: SyncCodec.encode(item)))
        // ...an older delete must NOT clobber it (apply-side LWW).
        applier.apply(SyncChange(collection: .pantryItems, itemId: item.id.uuidString,
                                 updatedAt: 200, deleted: true, payload: nil))
        XCTAssertEqual(PantryStore(defaults: d, userScope: "u1").all().map(\.name), ["Milk"])
    }

    // MARK: - Account deletion

    func testEraseRemovesPantryData() {
        let d = freshDefaults()
        PantryStore(defaults: d, userScope: "victim").upsert(PantryItem(name: "Tomatoes"))
        PantryStore(defaults: d, userScope: "keep").upsert(PantryItem(name: "Cheese"))
        AccountDataEraser.erase(userId: "victim", defaults: d)
        XCTAssertTrue(PantryStore(defaults: d, userScope: "victim").all().isEmpty)
        XCTAssertEqual(PantryStore(defaults: d, userScope: "keep").all().map(\.name), ["Cheese"])
    }

    // MARK: - Cross-device sync (Step 5 manual check, automated)

    /// Two devices for the SAME account, one shared (fake) server. An item added
    /// on device A must appear on device B after a push+pull, and a later delete
    /// on A must remove it from B — the exact outbox → push → pull → apply path
    /// the real app uses (reusing FakeSyncServer/FakeTransport from
    /// SyncEngineTests). Stands in for driving two live simulators.
    func testPantryItemSyncsAcrossDevices() async {
        let server = FakeSyncServer()
        let user = "same-account"
        let dA = freshDefaults()
        let dB = freshDefaults()

        let storeA = PantryStore(defaults: dA, userScope: user)
        let storeB = PantryStore(defaults: dB, userScope: user)
        let applierB = LocalSyncApplier(userId: user, defaults: dB)

        let engineA = SyncEngine(
            transport: FakeTransport(server: server),
            outbox: SyncOutbox(userId: user, defaults: dA),
            cursorStore: SyncCursorStore(userId: user, defaults: dA),
            apply: { _ in }  // A originates; nothing to apply back for this test
        )
        let engineB = SyncEngine(
            transport: FakeTransport(server: server),
            outbox: SyncOutbox(userId: user, defaults: dB),
            cursorStore: SyncCursorStore(userId: user, defaults: dB),
            apply: applierB.apply
        )

        // Device A adds an item (exactly what PantryModel.add does: write local
        // store + record a .pantryItems change into the outbox), then pushes.
        let item = PantryItem(name: "Olive oil")
        storeA.upsert(item)
        engineA.record(SyncChange(
            collection: .pantryItems, itemId: item.id.uuidString,
            updatedAt: 1_000, payload: SyncCodec.encode(item)
        ))
        try? await engineA.push()

        // Device B pulls → applies into its own PantryStore.
        try? await engineB.pull()
        XCTAssertEqual(storeB.all().map(\.name), ["Olive oil"], "item should sync A → B")
        XCTAssertEqual(storeB.all().first?.id, item.id, "same id preserved across devices")

        // Device A removes it later (higher updatedAt) → tombstone → B pulls.
        storeA.remove(id: item.id)
        engineA.record(SyncChange(
            collection: .pantryItems, itemId: item.id.uuidString,
            updatedAt: 2_000, deleted: true, payload: nil
        ))
        try? await engineA.push()
        try? await engineB.pull()
        XCTAssertTrue(storeB.all().isEmpty, "delete should propagate A → B")
    }
}
