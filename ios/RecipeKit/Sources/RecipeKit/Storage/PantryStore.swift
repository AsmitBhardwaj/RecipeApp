//
//  PantryStore.swift
//  RecipeKit
//
//  Local persistence for the Kitchen (pantry) — a single JSON-encoded
//  `[PantryItem]` under one key, the same lightweight pattern as `MealPlanStore`.
//  Account-scoped by user id (Stage 2b) so two accounts on one device stay
//  separate; the shared App Group suite keeps storage conventions consistent.
//
//  There is no checked/bought state to persist (unlike `GroceryCheckStore`): a
//  pantry item exists or it doesn't, and removing it is the only state change.
//

import Foundation

public struct PantryStore {

    /// Key holding the JSON-encoded `[PantryItem]`. Namespaced by account when a
    /// `userScope` is given (Stage 2b), legacy key otherwise.
    private static let baseKey = "pantry_items_v1"
    private let storageKey: String

    private let defaults: UserDefaults

    /// Production initializer. Falls back to `.standard` if the App Group suite
    /// can't be opened, so the pantry degrades to app-local rather than crashing.
    public init(suiteName: String = AppGroup.identifier, userScope: String? = nil) {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
        self.storageKey = scopedStorageKey(Self.baseKey, userScope)
    }

    /// Test/seam initializer: inject an ephemeral `UserDefaults` for host tests.
    public init(defaults: UserDefaults, userScope: String? = nil) {
        self.defaults = defaults
        self.storageKey = scopedStorageKey(Self.baseKey, userScope)
    }

    // MARK: - Reads

    /// Every pantry item, in stored (insertion) order.
    public func all() -> [PantryItem] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([PantryItem].self, from: data)) ?? []
    }

    // MARK: - Writes

    /// Insert or replace an item by id (upsert = remove-then-append), so an
    /// applied remote change can't duplicate a row already present locally.
    public func upsert(_ item: PantryItem) {
        var items = all().filter { $0.id != item.id }
        items.append(item)
        write(items)
    }

    /// Remove an item by id.
    public func remove(id: UUID) {
        write(all().filter { $0.id != id })
    }

    private func write(_ items: [PantryItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
