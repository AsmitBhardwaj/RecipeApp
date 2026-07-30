//
//  GroceryListModel.swift
//  RecipeApp
//
//  Observable coordinator for the Grocery List tab, wrapping `GroceryCheckStore`
//  (mirrors how `MealPlanModel` wraps `MealPlanStore`). It owns ONLY the two
//  pieces of state that persist: checked-off keys and hand-added manual items.
//
//  It deliberately owns NO ingredient list. The shopping list is derived fresh
//  in the view from `MealPlanModel` + `PendingJobsModel.recipes` every render, so
//  it always reflects the current meal plan and can never be stale. This model
//  just answers "is this key checked?" and "what did the user add by hand?".
//

import Foundation
import RecipeKit

@MainActor
final class GroceryListModel: ObservableObject {

    /// All checked keys across every period (day/week). Membership is looked up
    /// per-item with the item's full key.
    @Published private(set) var checkedKeys: Set<String> = []
    /// All hand-added items across every period; filtered per-period at read.
    @Published private(set) var manualItems: [GroceryManualItem] = []

    private let store: GroceryCheckStore

    init(store: GroceryCheckStore = GroceryCheckStore()) {
        self.store = store
        self.checkedKeys = store.checkedKeys()
        self.manualItems = store.manualItems()
    }

    // MARK: - Checked state

    func isChecked(_ fullKey: String) -> Bool {
        checkedKeys.contains(fullKey)
    }

    func toggle(_ fullKey: String) {
        store.setChecked(fullKey, !checkedKeys.contains(fullKey))
        checkedKeys = store.checkedKeys()
    }

    // MARK: - Manual items

    /// Hand-added items for one period, oldest first.
    func manualItems(inPeriod period: String) -> [GroceryManualItem] {
        manualItems
            .filter { $0.period == period }
            .sorted { $0.addedAt < $1.addedAt }
    }

    /// Add a hand-typed item to the given period (no-op on blank text).
    func addManual(name: String, period: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.addManual(GroceryManualItem(period: period, name: trimmed))
        manualItems = store.manualItems()
    }

    /// Remove a manual item and clear any checkmark it carried.
    func removeManual(_ item: GroceryManualItem) {
        store.setChecked(item.checkKey, false)
        store.removeManual(id: item.id)
        manualItems = store.manualItems()
        checkedKeys = store.checkedKeys()
    }
}
