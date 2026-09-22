//
//  MealPlanStalenessReproTests.swift
//  RecipeKitTests
//
//  Companion to GroceryStalenessReproTests, for the second wave of the same root
//  cause: a sync pull writes remote changes straight to the disk stores and never
//  touches the @Published view models, so a model seeded once (MealPlanModel /
//  PantryModel / CookbooksModel) stays stale mid-session until a cold relaunch.
//
//  MealPlanModel is the representative case (same feature family as the original
//  Grocery bug, with non-trivial week-grouped seeding). It lives in the app
//  target — no XCTest bundle — so this drives the exact mechanism against the REAL
//  RecipeKit pieces (FakeSyncServer + SyncEngine + LocalSyncApplier + real
//  MealPlanStore) and models MealPlanModel's contract directly:
//    • reload() groups store.all() into the visible week      (seed / refresh)
//    • the fix re-runs reload() after a pull applies new rows  (refreshFromStore)
//  It also pins the coordinator's gating signal — LocalSyncApplier.appliedRevision
//  bumps on an applied pull, and does NOT bump when nothing new arrives — which is
//  what makes SyncCoordinator refresh only on a real pull and not on every push.
//

import XCTest
@testable import RecipeKit

final class MealPlanStalenessReproTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "mealplan-stale-\(UUID().uuidString)")!
    }

    /// Mirrors MealPlanModel.reload(): group the store's entries by day for the
    /// visible week. Returns entries for one day key.
    private func reload(_ store: MealPlanStore, weekKeys: Set<String>, day: String) -> [MealPlanEntry] {
        var grouped: [String: [MealPlanEntry]] = [:]
        for entry in store.all() where weekKeys.contains(entry.dayKey) {
            grouped[entry.dayKey, default: []].append(entry)
        }
        return (grouped[day] ?? []).sorted { $0.addedAt < $1.addedAt }
    }

    func testMealPlanPicksUpEntryPlannedOnAnotherDeviceMidSession() async throws {
        let dayKey = "2026-09-23"
        // The visible week (Mon–Sun) containing that Wednesday.
        let weekKeys: Set<String> = [
            "2026-09-21", "2026-09-22", "2026-09-23", "2026-09-24",
            "2026-09-25", "2026-09-26", "2026-09-27",
        ]

        // ── Device A plans a dinner for Wed and pushes it.
        let server = FakeSyncServer()
        let entry = MealPlanEntry(id: "m1", dayKey: dayKey,
                                  recipeId: "r1", recipeTitle: "Creamy Tomato Chicken Pasta")
        _ = server.push([SyncChange(collection: .mealPlan, itemId: "m1", updatedAt: 100,
                                    payload: SyncCodec.encode(entry))])

        // ── Device B: app already running, MealPlanModel seeded ONCE from an empty
        //    disk (the entry hadn't synced yet).
        let defaultsB = freshDefaults()
        let applierB = LocalSyncApplier(userId: "userB", defaults: defaultsB)
        let mealStoreB = MealPlanStore(defaults: defaultsB, userScope: "userB")
        let seededSnapshot = reload(mealStoreB, weekKeys: weekKeys, day: dayKey)
        XCTAssertTrue(seededSnapshot.isEmpty)

        let engineB = SyncEngine(
            transport: FakeTransport(server: server),
            outbox: SyncOutbox(userId: "userB", defaults: defaultsB),
            cursorStore: SyncCursorStore(userId: "userB", defaults: defaultsB),
            apply: { applierB.apply($0) }
        )

        // ── Foreground mid-session → pull. Entry lands on disk; the applied-
        //    revision counter (the coordinator's refresh gate) bumps.
        let revisionBefore = applierB.appliedRevision
        try await engineB.pull()
        XCTAssertNotEqual(applierB.appliedRevision, revisionBefore,
                          "an applied pull must bump appliedRevision so the coordinator refreshes")

        // ── BUG: the once-seeded in-memory snapshot still shows nothing for Wed,
        //    even though the entry is now on disk.
        XCTAssertEqual(seededSnapshot.count, 0)
        XCTAssertEqual(mealStoreB.entries(on: dayKey).count, 1, "entry is on disk")

        // ── FIX: MealPlanModel.refreshFromStore() re-runs reload().
        let refreshed = reload(mealStoreB, weekKeys: weekKeys, day: dayKey)
        XCTAssertEqual(refreshed.count, 1)
        XCTAssertEqual(refreshed.first?.recipeTitle, "Creamy Tomato Chicken Pasta")
    }

    /// The refresh gate must NOT fire when a pull brings nothing new — otherwise
    /// every local-edit push would spuriously re-render every registered model.
    func testAppliedRevisionUnchangedWhenPullBringsNothingNew() async throws {
        let server = FakeSyncServer()   // empty server
        let defaults = freshDefaults()
        let applier = LocalSyncApplier(userId: "u", defaults: defaults)
        let engine = SyncEngine(
            transport: FakeTransport(server: server),
            outbox: SyncOutbox(userId: "u", defaults: defaults),
            cursorStore: SyncCursorStore(userId: "u", defaults: defaults),
            apply: { applier.apply($0) }
        )
        let before = applier.appliedRevision
        try await engine.pull()
        XCTAssertEqual(applier.appliedRevision, before, "no remote data → no refresh")
    }

    /// A stale (older) change that loses last-writer-wins must not bump the gate:
    /// nothing was written, so nothing should refresh.
    func testStaleLWWChangeDoesNotBumpAppliedRevision() {
        let defaults = freshDefaults()
        let applier = LocalSyncApplier(userId: "u", defaults: defaults)

        applier.apply(SyncChange(collection: .mealPlan, itemId: "m1", updatedAt: 200,
                                 payload: SyncCodec.encode(
                                    MealPlanEntry(id: "m1", dayKey: "2026-09-23",
                                                  recipeId: "r1", recipeTitle: "new"))))
        let afterFirst = applier.appliedRevision

        // Older update for the same item → ignored by apply-side LWW.
        applier.apply(SyncChange(collection: .mealPlan, itemId: "m1", updatedAt: 100,
                                 payload: SyncCodec.encode(
                                    MealPlanEntry(id: "m1", dayKey: "2026-09-23",
                                                  recipeId: "r1", recipeTitle: "old"))))
        XCTAssertEqual(applier.appliedRevision, afterFirst, "stale change writes nothing → no bump")
    }
}
