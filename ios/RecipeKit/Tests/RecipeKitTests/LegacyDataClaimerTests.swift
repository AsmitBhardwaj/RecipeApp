//
//  LegacyDataClaimerTests.swift
//  RecipeKitTests
//
//  Stage 4 "claim your data": pre-account (legacy, nil-scope) local data is
//  migrated into the signed-in account's scoped stores AND queued for upload,
//  exactly once per device.
//

import XCTest
@testable import RecipeKit

final class LegacyDataClaimerTests: XCTestCase {

    private let userId = "user-abc"

    /// A fresh, isolated suite per test — one `UserDefaults` shared by the legacy
    /// and scoped stores, exactly as the claimer wires them.
    private func makeDefaults(_ function: String = #function) -> UserDefaults {
        let suite = "LegacyDataClaimerTests.\(function)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func recipe(_ id: String) -> Recipe {
        Recipe(
            recipeId: id, canonicalVideoId: "vid_\(id)", title: "Dish \(id)",
            servings: Servings(amount: nil, unit: nil),
            prepTimeMinutes: nil, cookTimeMinutes: nil, totalTimeMinutes: nil,
            ingredients: [], instructions: [],
            confidence: nil, sourceType: .caption, imageUrl: nil, imageSource: .none, transcript: nil
        )
    }

    // MARK: - Full migration

    func testClaimsAllCollectionsIntoScopeAndOutbox() {
        let d = makeDefaults()

        // Seed legacy (nil-scope) stores.
        let lr = RecipeStore(defaults: d, userScope: nil)
        lr.upsert(recipe("r1")); lr.upsert(recipe("r2"))
        let lc = CookbookStore(defaults: d, userScope: nil)
        let cookbook = Cookbook(id: "cb1", name: "Weeknight")
        lc.upsert(cookbook)
        let lm = CookbookMembershipStore(defaults: d, userScope: nil)
        lm.setCookbooks(forRecipe: "r1", to: ["cb1"])
        let lmp = MealPlanStore(defaults: d, userScope: nil)
        lmp.add(MealPlanEntry(id: "m1", dayKey: "2026-08-31", mealSlot: .dinner,
                              recipeId: "r1", recipeTitle: "Dish r1", recipeImageURL: nil))
        let lg = GroceryCheckStore(defaults: d, userScope: nil)
        lg.addManual(GroceryManualItem(id: "g1", period: "day:2026-08-31", name: "Olive oil"))
        lg.setChecked("day:2026-08-31|line-x", true)

        // Claim.
        let summary = LegacyDataClaimer(userId: userId, defaults: d).claimIfNeeded()

        // Summary counts.
        XCTAssertEqual(summary?.recipes, 2)
        XCTAssertEqual(summary?.cookbooks, 1)
        XCTAssertEqual(summary?.mealPlanEntries, 1)
        XCTAssertEqual(summary?.groceryItems, 2)  // 1 manual + 1 check
        XCTAssertEqual(summary?.total, 6)

        // Scoped stores now hold everything.
        XCTAssertEqual(Set(RecipeStore(defaults: d, userScope: userId).all().map(\.recipeId)), ["r1", "r2"])
        XCTAssertEqual(CookbookStore(defaults: d, userScope: userId).all().map(\.id), ["cb1"])
        XCTAssertEqual(CookbookMembershipStore(defaults: d, userScope: userId).recipeIds(inCookbook: "cb1"), ["r1"])
        XCTAssertEqual(MealPlanStore(defaults: d, userScope: userId).all().map(\.id), ["m1"])
        let g = GroceryCheckStore(defaults: d, userScope: userId)
        XCTAssertEqual(g.manualItems().map(\.id), ["g1"])
        XCTAssertTrue(g.checkedKeys().contains("day:2026-08-31|line-x"))

        // Outbox queued one change per record (2 lib + 1 cookbook + 1 membership + 1 meal + 1 manual + 1 check = 7).
        let queued = SyncOutbox(userId: userId, defaults: d).pending()
        XCTAssertEqual(queued.count, 7)
        XCTAssertEqual(Set(queued.filter { $0.collection == .library }.map(\.itemId)), ["r1", "r2"])
        XCTAssertTrue(queued.contains { $0.collection == .cookbookMembership && $0.itemId == "cb1|r1" })

        // Legacy sources cleared.
        XCTAssertTrue(RecipeStore(defaults: d, userScope: nil).all().isEmpty)
        XCTAssertTrue(MealPlanStore(defaults: d, userScope: nil).all().isEmpty)
        XCTAssertTrue(GroceryCheckStore(defaults: d, userScope: nil).manualItems().isEmpty)
    }

    // MARK: - Idempotency

    func testSecondClaimIsNoOpAndDoesNotDuplicate() {
        let d = makeDefaults()
        RecipeStore(defaults: d, userScope: nil).upsert(recipe("r1"))

        let first = LegacyDataClaimer(userId: userId, defaults: d).claimIfNeeded()
        XCTAssertEqual(first?.recipes, 1)

        // A second run (same or different account) finds the flag set → nil, no new
        // queue entries, no re-population of the already-empty legacy store.
        let second = LegacyDataClaimer(userId: userId, defaults: d).claimIfNeeded()
        XCTAssertNil(second)
        XCTAssertEqual(SyncOutbox(userId: userId, defaults: d).pending().count, 1)

        let otherAccount = LegacyDataClaimer(userId: "user-xyz", defaults: d).claimIfNeeded()
        XCTAssertNil(otherAccount)
        XCTAssertTrue(RecipeStore(defaults: d, userScope: "user-xyz").all().isEmpty)
    }

    // MARK: - Nothing to claim

    func testNoLegacyDataReturnsNilButStillMarksClaimed() {
        let d = makeDefaults()
        let claimer = LegacyDataClaimer(userId: userId, defaults: d)

        XCTAssertNil(claimer.claimIfNeeded())          // nothing to migrate
        XCTAssertTrue(LegacyDataClaimer(userId: userId, defaults: d).alreadyClaimed)
    }

    // MARK: - LWW protection

    func testClaimStampsMetadataSoPullsDoNotClobber() {
        let d = makeDefaults()
        GroceryCheckStore(defaults: d, userScope: nil)
            .addManual(GroceryManualItem(id: "g1", period: "day:2026-08-31", name: "Olive oil"))

        _ = LegacyDataClaimer(userId: userId, defaults: d).claimIfNeeded()

        // The metadata clock is set for the claimed item, so LocalSyncApplier will
        // ignore an older server record for it.
        let meta = SyncMetadataStore(userId: userId, defaults: d)
        XCTAssertNotNil(meta.updatedAt(.groceryManual, "g1"))
    }
}
