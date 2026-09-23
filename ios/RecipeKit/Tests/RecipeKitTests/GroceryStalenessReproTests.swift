//
//  GroceryStalenessReproTests.swift
//  RecipeKitTests
//
//  Reproduces (and then confirms the fix for) the Grocery List staleness bug:
//  a meal planned on device A syncs to device B, but B's Grocery List showed the
//  empty "Nothing to shop for" state because the recipe body — hydrated straight
//  to disk (RecipeStore) by the sync pull — never made it into the in-memory
//  recipe list that the grocery derivation resolves against.
//
//  PendingJobsModel and GroceryListView live in the app target, which has no
//  XCTest bundle, so this test exercises the exact mechanism they rely on against
//  the REAL RecipeKit components:
//    • real two-device sync (FakeSyncServer + SyncEngine + LocalSyncApplier)
//    • real MealPlanStore / RecipeStore on disk
//    • real GroceryAggregator derivation
//  and models PendingJobsModel's recipe-list contract directly:
//    • seed-once from RecipeStore.all() at init  (the buggy behavior)
//    • refreshFromStore() merge after hydration  (the fix)
//

import XCTest
@testable import RecipeKit

final class GroceryStalenessReproTests: XCTestCase {

    // MARK: - Fixtures

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "grocery-stale-\(UUID().uuidString)")!
    }

    private func pasta(id: String = "r1") -> Recipe {
        Recipe(
            recipeId: id, canonicalVideoId: "v1", title: "Creamy Tomato Chicken Pasta",
            servings: Servings(amount: 2, unit: nil),
            prepTimeMinutes: nil, cookTimeMinutes: nil, totalTimeMinutes: nil,
            ingredients: [
                Ingredient(quantity: 200, unit: "g", name: "pasta", notes: nil),
                Ingredient(quantity: 1, unit: "cup", name: "tomato sauce", notes: nil),
                Ingredient(quantity: 2, unit: nil, name: "chicken breast", notes: nil),
            ],
            instructions: [Instruction(stepNumber: 1, text: "Cook it.")],
            confidence: nil, sourceType: .caption, imageUrl: nil, imageSource: .none,
            transcript: nil
        )
    }

    /// Mirrors GroceryListView.resolution + .sections: resolve meal-plan entries
    /// against an in-memory recipe list, then aggregate. Returns the derived line
    /// items and the count of entries whose recipe wasn't loaded.
    private func derive(
        dayKey: String,
        mealStore: MealPlanStore,
        recipes: [Recipe]
    ) -> (items: [GroceryLineItem], unresolved: Int) {
        let byId = Dictionary(recipes.map { ($0.recipeId, $0) }, uniquingKeysWith: { first, _ in first })
        var resolved: [Recipe] = []
        var unresolved = 0
        for entry in mealStore.entries(on: dayKey) {
            if let r = byId[entry.recipeId] { resolved.append(r) } else { unresolved += 1 }
        }
        return (GroceryAggregator.aggregate(recipes: resolved), unresolved)
    }

    // MARK: - Reproduction

    func testGroceryListPicksUpMealPlannedOnAnotherDeviceMidSession() async throws {
        let dayKey = "2026-09-23"   // Wed Sep 23, the reported day
        let server = FakeSyncServer()

        // ── Device A: plan the pasta for Wed and save the recipe. Both the
        //    meal-plan entry and the library membership get pushed to the server.
        let entry = MealPlanEntry(id: "m1", dayKey: dayKey,
                                  recipeId: "r1", recipeTitle: "Creamy Tomato Chicken Pasta")
        _ = server.push([
            SyncChange(collection: .mealPlan, itemId: "m1", updatedAt: 100,
                       payload: SyncCodec.encode(entry)),
            SyncChange(collection: .library, itemId: "r1", updatedAt: 100,
                       payload: SyncCodec.encode(LibraryPayload(recipeId: "r1"))),
        ])

        // ── Device B: real applier + stores. Simulate the app already running:
        //    its in-memory recipe list was seeded ONCE at launch, when disk was
        //    empty (the recipe hadn't synced yet).
        let defaultsB = freshDefaults()
        let applierB = LocalSyncApplier(userId: "userB", defaults: defaultsB)
        let mealStoreB = MealPlanStore(defaults: defaultsB, userScope: "userB")
        let recipeStoreB = RecipeStore(defaults: defaultsB, userScope: "userB")
        var inMemoryRecipes = recipeStoreB.all()   // PendingJobsModel.init seed → []
        XCTAssertTrue(inMemoryRecipes.isEmpty)

        let engineB = SyncEngine(
            transport: FakeTransport(server: server),
            outbox: SyncOutbox(userId: "userB", defaults: defaultsB),
            cursorStore: SyncCursorStore(userId: "userB", defaults: defaultsB),
            apply: { applierB.apply($0) }
        )

        // ── Foreground mid-sync: device B pulls. The meal-plan entry lands on
        //    disk; the recipe body is flagged for hydration but not yet fetched.
        try await engineB.pull()
        XCTAssertEqual(mealStoreB.entries(on: dayKey).count, 1,
                       "meal plan entry should have synced to disk")
        XCTAssertTrue(applierB.pendingRecipeHydration.contains("r1"))

        // ── BUG: with only the launch-time seed, the grocery derivation finds the
        //    planned meal but cannot resolve its recipe → zero items. Pre-fix this
        //    collapsed into the plain "Nothing to shop for" empty-cart state.
        let buggy = derive(dayKey: dayKey, mealStore: mealStoreB, recipes: inMemoryRecipes)
        XCTAssertTrue(buggy.items.isEmpty, "reproduces the empty grocery list")
        XCTAssertEqual(buggy.unresolved, 1,
                       "a meal IS planned — the secondary fix shows the unresolved state, not an empty day")

        // ── Hydration completes (SyncCoordinator.hydrateIfNeeded): bodies fetched
        //    from the server and written to disk.
        applierB.hydrate([pasta()])
        XCTAssertEqual(recipeStoreB.all().count, 1)

        // ── THE FIX: PendingJobsModel.refreshFromStore() merges new disk bodies
        //    into the in-memory list (merge-never-overwrite).
        let known = Set(inMemoryRecipes.map(\.recipeId))
        inMemoryRecipes.append(contentsOf: recipeStoreB.all().filter { !known.contains($0.recipeId) })

        // ── FIXED: the same derivation now yields the pasta's ingredients.
        let fixed = derive(dayKey: dayKey, mealStore: mealStoreB, recipes: inMemoryRecipes)
        XCTAssertEqual(fixed.unresolved, 0)
        XCTAssertFalse(fixed.items.isEmpty, "grocery items appear without a relaunch")
        let names = Set(fixed.items.map { $0.name.lowercased() })
        XCTAssertTrue(names.contains("pasta"))
        XCTAssertTrue(names.contains("chicken breast"))
    }

    /// The merge must never drop a recipe resolved this session (the invariant
    /// every other PendingJobsModel.recipes consumer depends on).
    func testRefreshFromStoreMergeNeverOverwritesSessionRecipes() {
        let defaults = freshDefaults()
        let recipeStore = RecipeStore(defaults: defaults, userScope: "u")

        // Session recipe held only in memory (e.g. just completed this session,
        // already on disk too) plus a different body arriving via hydration.
        let sessionRecipe = pasta(id: "session")
        var inMemory = [sessionRecipe]
        recipeStore.upsert(sessionRecipe)
        recipeStore.upsert(pasta(id: "hydrated"))

        let known = Set(inMemory.map(\.recipeId))
        inMemory.append(contentsOf: recipeStore.all().filter { !known.contains($0.recipeId) })

        XCTAssertEqual(inMemory.count, 2)
        XCTAssertTrue(inMemory.contains { $0.recipeId == "session" })
        XCTAssertTrue(inMemory.contains { $0.recipeId == "hydrated" })
        // No duplicate of the session recipe despite it also being on disk.
        XCTAssertEqual(inMemory.filter { $0.recipeId == "session" }.count, 1)
    }
}
