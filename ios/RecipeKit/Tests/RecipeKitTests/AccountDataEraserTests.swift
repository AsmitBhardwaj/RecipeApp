//
//  AccountDataEraserTests.swift
//  RecipeKitTests
//
//  Stage 5: deleting an account wipes that account's scoped local data, while
//  leaving a second account's data and device-global keys untouched.
//

import XCTest
@testable import RecipeKit

final class AccountDataEraserTests: XCTestCase {

    private func makeDefaults(_ function: String = #function) -> UserDefaults {
        let suite = "AccountDataEraserTests.\(function)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func recipe(_ id: String) -> Recipe {
        Recipe(
            recipeId: id, canonicalVideoId: "vid_\(id)", title: "Dish",
            servings: Servings(amount: nil, unit: nil),
            prepTimeMinutes: nil, cookTimeMinutes: nil, totalTimeMinutes: nil,
            ingredients: [], instructions: [],
            confidence: nil, sourceType: .caption, imageUrl: nil, imageSource: .none, transcript: nil
        )
    }

    func testEraseRemovesOnlyTheTargetAccountsData() {
        let d = makeDefaults()
        let victim = "user-del"
        let survivor = "user-keep"

        // Seed both accounts across the scoped stores + sync bookkeeping.
        for user in [victim, survivor] {
            RecipeStore(defaults: d, userScope: user).upsert(recipe("r-\(user)"))
            GroceryCheckStore(defaults: d, userScope: user)
                .addManual(GroceryManualItem(id: "g-\(user)", period: "day:2026-08-31", name: "Milk"))
            CookbookStore(defaults: d, userScope: user).upsert(Cookbook(id: "cb-\(user)", name: "Book"))
            SyncOutbox(userId: user, defaults: d)
                .enqueue(SyncChange(collection: .library, itemId: "r-\(user)", updatedAt: 1, payload: nil))
            SyncCursorStore(userId: user, defaults: d).setCursor(42)
            SyncMetadataStore(userId: user, defaults: d).setUpdatedAt(.library, "r-\(user)", 1)
        }
        // A device-global key that must survive.
        d.set(true, forKey: LegacyDataClaimer.claimedFlagKey)

        AccountDataEraser.erase(userId: victim, defaults: d)

        // Victim: everything gone.
        XCTAssertTrue(RecipeStore(defaults: d, userScope: victim).all().isEmpty)
        XCTAssertTrue(GroceryCheckStore(defaults: d, userScope: victim).manualItems().isEmpty)
        XCTAssertTrue(CookbookStore(defaults: d, userScope: victim).all().isEmpty)
        XCTAssertTrue(SyncOutbox(userId: victim, defaults: d).pending().isEmpty)
        XCTAssertEqual(SyncCursorStore(userId: victim, defaults: d).cursor(), 0)
        XCTAssertNil(SyncMetadataStore(userId: victim, defaults: d).updatedAt(.library, "r-\(victim)"))

        // Survivor: fully intact.
        XCTAssertEqual(RecipeStore(defaults: d, userScope: survivor).all().map(\.recipeId), ["r-\(survivor)"])
        XCTAssertEqual(CookbookStore(defaults: d, userScope: survivor).all().map(\.id), ["cb-\(survivor)"])
        XCTAssertEqual(SyncOutbox(userId: survivor, defaults: d).pending().count, 1)
        XCTAssertEqual(SyncCursorStore(userId: survivor, defaults: d).cursor(), 42)

        // Device-global flag untouched.
        XCTAssertTrue(d.bool(forKey: LegacyDataClaimer.claimedFlagKey))
    }
}
