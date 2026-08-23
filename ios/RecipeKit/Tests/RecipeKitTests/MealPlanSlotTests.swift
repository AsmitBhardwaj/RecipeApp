//
//  MealPlanSlotTests.swift
//  RecipeKitTests
//
//  Covers the meal-slot data model change: the decode-time migration (legacy
//  entries with no `mealSlot` default to .dinner), round-tripping with a slot,
//  and the store-level persistence that the add/change/remove flows rely on.
//

import XCTest
@testable import RecipeKit

final class MealPlanSlotTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "mealplan-slot-tests-\(UUID().uuidString)")!
    }

    // MARK: - Migration

    func testLegacyEntryWithoutMealSlotDecodesToDinner() throws {
        // A payload shaped exactly like a pre-slots persisted entry (no mealSlot).
        let legacy = """
        {
          "id": "e1",
          "dayKey": "2026-08-24",
          "recipeId": "r1",
          "recipeTitle": "Old Recipe",
          "recipeImageURL": null,
          "addedAt": 0
        }
        """.data(using: .utf8)!

        let entry = try JSONDecoder().decode(MealPlanEntry.self, from: legacy)
        XCTAssertEqual(entry.mealSlot, .dinner)
        XCTAssertEqual(entry.recipeId, "r1")
        XCTAssertEqual(entry.recipeTitle, "Old Recipe")
    }

    func testNewEntryRoundTripsWithItsSlot() throws {
        let entry = MealPlanEntry(dayKey: "2026-08-24", mealSlot: .breakfast,
                                  recipeId: "r2", recipeTitle: "Pancakes")
        let data = try JSONEncoder().encode(entry)
        // Encoding must include the slot (so re-saved legacy data upgrades).
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("breakfast"))
        let decoded = try JSONDecoder().decode(MealPlanEntry.self, from: data)
        XCTAssertEqual(decoded.mealSlot, .breakfast)
    }

    func testDefaultSlotIsDinner() {
        let entry = MealPlanEntry(dayKey: "2026-08-24", recipeId: "r", recipeTitle: "T")
        XCTAssertEqual(entry.mealSlot, .dinner)
    }

    // MARK: - Store-level add / query / change / remove

    func testStoreAddAndQueryBySlot() {
        let store = MealPlanStore(defaults: makeDefaults())
        store.add(MealPlanEntry(dayKey: "2026-08-24", mealSlot: .breakfast, recipeId: "r1", recipeTitle: "Eggs"))
        store.add(MealPlanEntry(dayKey: "2026-08-24", mealSlot: .snacks, recipeId: "r2", recipeTitle: "Chips"))
        store.add(MealPlanEntry(dayKey: "2026-08-24", mealSlot: .snacks, recipeId: "r3", recipeTitle: "Nuts"))

        let day = store.entries(on: "2026-08-24")
        XCTAssertEqual(day.count, 3)
        // Multiple entries per slot are allowed (two snacks).
        XCTAssertEqual(day.filter { $0.mealSlot == .snacks }.count, 2)
        XCTAssertEqual(day.filter { $0.mealSlot == .breakfast }.map(\.recipeId), ["r1"])
        XCTAssertTrue(day.filter { $0.mealSlot == .lunch }.isEmpty)
    }

    func testRemoveById() {
        let store = MealPlanStore(defaults: makeDefaults())
        let e = MealPlanEntry(dayKey: "2026-08-24", mealSlot: .dinner, recipeId: "r1", recipeTitle: "Stew")
        store.add(e)
        store.remove(id: e.id)
        XCTAssertTrue(store.entries(on: "2026-08-24").isEmpty)
    }

    /// The "change" flow = remove the old entry, add the replacement in the SAME
    /// slot. This pins that store-level behavior.
    func testChangeReplacesInSameSlot() {
        let store = MealPlanStore(defaults: makeDefaults())
        let original = MealPlanEntry(dayKey: "2026-08-24", mealSlot: .lunch, recipeId: "r1", recipeTitle: "Salad")
        store.add(original)

        store.remove(id: original.id)
        store.add(MealPlanEntry(dayKey: original.dayKey, mealSlot: original.mealSlot,
                                recipeId: "r2", recipeTitle: "Soup"))

        let lunch = store.entries(on: "2026-08-24").filter { $0.mealSlot == .lunch }
        XCTAssertEqual(lunch.map(\.recipeId), ["r2"])
    }
}
