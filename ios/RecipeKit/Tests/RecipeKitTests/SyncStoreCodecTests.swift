//
//  SyncStoreCodecTests.swift
//  RecipeKitTests
//
//  Stage 2b-ii chunk 1: account-scoping of the stores, the sync-metadata map,
//  payload codecs, and the LocalSyncApplier (apply-side last-writer-wins + each
//  collection's write path + recipe-hydration tracking).
//

import XCTest
@testable import RecipeKit

final class SyncStoreCodecTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "sync-store-\(UUID().uuidString)")!
    }

    // MARK: Account-scoping

    func testStoresAreAccountScoped() {
        let defaults = freshDefaults()
        let alice = CookbookStore(defaults: defaults, userScope: "alice")
        let bob = CookbookStore(defaults: defaults, userScope: "bob")
        alice.upsert(Cookbook(id: "c1", name: "Alice book"))
        XCTAssertEqual(alice.all().count, 1)
        XCTAssertEqual(bob.all().count, 0)  // isolated
    }

    func testLegacyKeyUnchangedWhenUnscoped() {
        let defaults = freshDefaults()
        let legacy = MealPlanStore(defaults: defaults)              // nil scope
        legacy.add(MealPlanEntry(id: "m1", dayKey: "d", recipeId: "r", recipeTitle: "t"))
        // A scoped store must NOT see legacy data (separate key).
        XCTAssertEqual(MealPlanStore(defaults: defaults, userScope: "alice").all().count, 0)
        XCTAssertEqual(legacy.all().count, 1)
    }

    // MARK: Metadata map

    func testMetadataRoundTripsAndLWW() {
        let meta = SyncMetadataStore(userId: "u1", defaults: freshDefaults())
        XCTAssertNil(meta.updatedAt(.cookbook, "c1"))
        meta.setUpdatedAt(.cookbook, "c1", 100)
        XCTAssertEqual(meta.updatedAt(.cookbook, "c1"), 100)
        meta.remove(.cookbook, "c1")
        XCTAssertNil(meta.updatedAt(.cookbook, "c1"))
    }

    // MARK: Codecs

    func testMealPlanPayloadRoundTrips() {
        // Pin `addedAt` to a whole-second epoch value. The codec encodes dates as
        // `.secondsSince1970` (a Double); a default `Date()` carries a sub-second
        // fraction that isn't always bit-exact after the Double round-trip, which
        // made this equality check intermittently fail. A whole-second timestamp
        // is exactly representable, so the round-trip is deterministic.
        let entry = MealPlanEntry(id: "m1", dayKey: "2026-08-28", recipeId: "r1", recipeTitle: "Tacos",
                                  addedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let payload = SyncCodec.encode(entry)
        let back = SyncCodec.decode(MealPlanEntry.self, from: payload)
        XCTAssertEqual(back, entry)
    }

    func testGroceryCheckPayloadRoundTrips() {
        let payload = SyncCodec.encode(GroceryCheckPayload(checked: true))
        XCTAssertEqual(SyncCodec.decode(GroceryCheckPayload.self, from: payload)?.checked, true)
    }

    // MARK: Applier — per collection

    private func applier(_ defaults: UserDefaults) -> LocalSyncApplier {
        LocalSyncApplier(userId: "u1", defaults: defaults)
    }

    func testApplyMealPlanInsertAndDelete() {
        let defaults = freshDefaults()
        let a = applier(defaults)
        let store = MealPlanStore(defaults: defaults, userScope: "u1")
        let entry = MealPlanEntry(id: "m1", dayKey: "d", recipeId: "r", recipeTitle: "t")

        a.apply(SyncChange(collection: .mealPlan, itemId: "m1", updatedAt: 10, payload: SyncCodec.encode(entry)))
        XCTAssertEqual(store.all().count, 1)

        a.apply(SyncChange(collection: .mealPlan, itemId: "m1", updatedAt: 20, deleted: true))
        XCTAssertEqual(store.all().count, 0)
    }

    func testApplyIsLastWriterWins() {
        let defaults = freshDefaults()
        let a = applier(defaults)
        let store = CookbookStore(defaults: defaults, userScope: "u1")

        a.apply(SyncChange(collection: .cookbook, itemId: "c1", updatedAt: 200,
                           payload: SyncCodec.encode(Cookbook(id: "c1", name: "new"))))
        // An OLDER change must be ignored.
        a.apply(SyncChange(collection: .cookbook, itemId: "c1", updatedAt: 100,
                           payload: SyncCodec.encode(Cookbook(id: "c1", name: "old"))))
        XCTAssertEqual(store.all().first?.name, "new")
    }

    func testApplyMembershipAddAndRemove() {
        let defaults = freshDefaults()
        let a = applier(defaults)
        let store = CookbookMembershipStore(defaults: defaults, userScope: "u1")
        let link = MembershipPayload(cookbookId: "cb1", recipeId: "r1")
        let id = MembershipPayload.itemId(cookbookId: "cb1", recipeId: "r1")

        a.apply(SyncChange(collection: .cookbookMembership, itemId: id, updatedAt: 10, payload: SyncCodec.encode(link)))
        XCTAssertEqual(store.cookbookIds(forRecipe: "r1"), ["cb1"])

        a.apply(SyncChange(collection: .cookbookMembership, itemId: id, updatedAt: 20, deleted: true, payload: SyncCodec.encode(link)))
        XCTAssertEqual(store.cookbookIds(forRecipe: "r1"), [])
    }

    func testApplyGroceryCheck() {
        let defaults = freshDefaults()
        let a = applier(defaults)
        let store = GroceryCheckStore(defaults: defaults, userScope: "u1")
        a.apply(SyncChange(collection: .groceryCheck, itemId: "day:1|milk", updatedAt: 10,
                           payload: SyncCodec.encode(GroceryCheckPayload(checked: true))))
        XCTAssertTrue(store.checkedKeys().contains("day:1|milk"))
    }

    func testLibraryTracksHydrationAndDeletes() {
        let defaults = freshDefaults()
        let a = applier(defaults)
        let recipes = RecipeStore(defaults: defaults, userScope: "u1")

        // Membership for a recipe we don't have the body for → hydration need.
        a.apply(SyncChange(collection: .library, itemId: "r1", updatedAt: 10,
                           payload: SyncCodec.encode(LibraryPayload(recipeId: "r1"))))
        XCTAssertTrue(a.pendingRecipeHydration.contains("r1"))

        // Hydrate it → body stored, pending cleared.
        a.hydrate([Recipe(recipeId: "r1", canonicalVideoId: "v1", title: "Tacos",
                          servings: Servings(amount: nil, unit: nil),
                          prepTimeMinutes: nil, cookTimeMinutes: nil, totalTimeMinutes: nil,
                          ingredients: [], instructions: [], confidence: nil,
                          sourceType: .caption, imageUrl: nil, imageSource: .none,
                          transcript: nil)])
        XCTAssertFalse(a.pendingRecipeHydration.contains("r1"))
        XCTAssertEqual(recipes.all().count, 1)

        // Delete removes the body.
        a.apply(SyncChange(collection: .library, itemId: "r1", updatedAt: 20, deleted: true))
        XCTAssertEqual(recipes.all().count, 0)
    }
}
