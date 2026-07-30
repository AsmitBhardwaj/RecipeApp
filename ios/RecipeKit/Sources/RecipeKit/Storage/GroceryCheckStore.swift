//
//  GroceryCheckStore.swift
//  RecipeKit
//
//  Local persistence for the ONLY two pieces of grocery-list state that aren't
//  derived fresh from the meal plan on every view: which items are checked off,
//  and any free-form items the user typed in by hand.
//
//  Same lightweight pattern as `MealPlanStore` / `PendingJobStore`: JSON blobs
//  under fixed keys in the App Group `UserDefaults`. Survives relaunches, no
//  external service, no cross-device sync — matching the "no accounts yet"
//  reality.
//
//  The derived shopping list itself is deliberately NOT stored here: it's
//  recomputed from Meal Plan state every time the tab is shown, so it can never
//  go stale. Checked-state is stored as a set of stable string keys (period +
//  item identity) so it re-attaches to the freshly-derived list even as the
//  underlying recipe set shifts.
//

import Foundation

public struct GroceryCheckStore {

    /// Set<String> of full checked keys ("period|itemKey").
    private static let checkedKey = "grocery_checked_keys_v1"
    /// [GroceryManualItem] of hand-added items.
    private static let manualKey = "grocery_manual_items_v1"

    private let defaults: UserDefaults

    /// Production initializer. Falls back to `.standard` if the App Group suite
    /// can't be opened, so the list degrades to app-local rather than crashing.
    public init(suiteName: String = AppGroup.identifier) {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    /// Test/seam initializer: inject an ephemeral `UserDefaults` for host tests.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    // MARK: - Checked state

    public func checkedKeys() -> Set<String> {
        guard let data = defaults.data(forKey: Self.checkedKey) else { return [] }
        return (try? JSONDecoder().decode(Set<String>.self, from: data)) ?? []
    }

    /// Set or clear the checked flag for a full key.
    public func setChecked(_ key: String, _ checked: Bool) {
        var keys = checkedKeys()
        if checked { keys.insert(key) } else { keys.remove(key) }
        guard let data = try? JSONEncoder().encode(keys) else { return }
        defaults.set(data, forKey: Self.checkedKey)
    }

    // MARK: - Manual items

    public func manualItems() -> [GroceryManualItem] {
        guard let data = defaults.data(forKey: Self.manualKey) else { return [] }
        return (try? JSONDecoder().decode([GroceryManualItem].self, from: data)) ?? []
    }

    public func addManual(_ item: GroceryManualItem) {
        var items = manualItems()
        items.append(item)
        writeManual(items)
    }

    public func removeManual(id: String) {
        writeManual(manualItems().filter { $0.id != id })
    }

    private func writeManual(_ items: [GroceryManualItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: Self.manualKey)
    }
}
