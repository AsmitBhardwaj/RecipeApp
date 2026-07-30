//
//  RecipeStoreTests.swift
//  RecipeKitTests
//
//  Covers the on-device recipe cache: that recipes round-trip through
//  UserDefaults, and that `upsert` keeps the list newest-first and de-duplicated
//  by recipeId (the behavior the Recipes list / Meal Plan picker / Grocery List
//  all rely on across relaunches).
//

import XCTest
@testable import RecipeKit

final class RecipeStoreTests: XCTestCase {

    /// A fresh, isolated UserDefaults suite per test so nothing touches the real
    /// App Group container or leaks between tests.
    private func makeStore(_ function: String = #function) -> (RecipeStore, UserDefaults) {
        let suite = "RecipeStoreTests.\(function)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (RecipeStore(defaults: defaults), defaults)
    }

    private func recipe(_ id: String, title: String = "Dish") -> Recipe {
        Recipe(
            recipeId: id,
            canonicalVideoId: "vid_\(id)",
            title: title,
            servings: Servings(amount: nil, unit: nil),
            prepTimeMinutes: nil,
            cookTimeMinutes: nil,
            totalTimeMinutes: nil,
            ingredients: [Ingredient(quantity: 1, unit: "cup", name: "flour", notes: nil)],
            instructions: [Instruction(stepNumber: 1, text: "Mix.")],
            confidence: nil,
            sourceType: .caption,
            imageUrl: nil,
            imageSource: .none,
            transcript: nil
        )
    }

    // MARK: - Round-trip

    func testEmptyStoreReturnsNothing() {
        let (store, _) = makeStore()
        XCTAssertEqual(store.all().count, 0)
    }

    func testUpsertRoundTripsThroughDefaults() {
        let (store, defaults) = makeStore()
        store.upsert(recipe("a", title: "Pasta"))

        // A brand-new store over the SAME defaults sees the persisted recipe —
        // i.e. it survives the equivalent of a relaunch, not just this instance.
        let reopened = RecipeStore(defaults: defaults)
        let all = reopened.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.recipeId, "a")
        XCTAssertEqual(all.first?.title, "Pasta")
        XCTAssertEqual(all.first?.ingredients.first?.name, "flour")
    }

    // MARK: - Ordering / de-duplication

    func testUpsertInsertsNewestFirst() {
        let (store, _) = makeStore()
        store.upsert(recipe("a"))
        store.upsert(recipe("b"))
        store.upsert(recipe("c"))

        XCTAssertEqual(store.all().map(\.recipeId), ["c", "b", "a"])
    }

    func testUpsertExistingMovesToFrontWithoutDuplicating() {
        let (store, _) = makeStore()
        store.upsert(recipe("a"))
        store.upsert(recipe("b"))
        store.upsert(recipe("c"))

        // Re-upserting "a" (e.g. re-extracted / re-completed) moves it to the
        // front and must NOT create a second "a".
        store.upsert(recipe("a", title: "Updated"))

        let all = store.all()
        XCTAssertEqual(all.map(\.recipeId), ["a", "c", "b"])
        XCTAssertEqual(all.filter { $0.recipeId == "a" }.count, 1)
        XCTAssertEqual(all.first?.title, "Updated")
    }

    func testRemoveDeletesById() {
        let (store, _) = makeStore()
        store.upsert(recipe("a"))
        store.upsert(recipe("b"))

        store.remove(recipeId: "a")

        XCTAssertEqual(store.all().map(\.recipeId), ["b"])
    }
}
