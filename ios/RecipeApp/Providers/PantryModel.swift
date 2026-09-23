//
//  PantryModel.swift
//  RecipeApp
//
//  Observable coordinator for the Kitchen tab, wrapping `PantryStore` (mirrors
//  how `GroceryListModel` wraps `GroceryCheckStore`, minus all the checked-state
//  machinery). The pantry is a single flat list of name entries — no periods, no
//  bought/checked flag. Removing an item IS the "used it up" action.
//
//  Every mutation writes the local store AND records a change on the generic sync
//  hub under the `pantryItems` collection, so it reaches the user's other devices
//  the same way grocery/meal-plan edits do.
//

import Foundation
import RecipeKit

@MainActor
final class PantryModel: ObservableObject, SyncRefreshable {

    /// Every pantry item, newest first (see `sortedItems`).
    @Published private(set) var items: [PantryItem] = []

    private let store: PantryStore
    /// Sync hub (nil in previews/unscoped builds → no sync recording).
    private let sync: SyncCoordinator?

    init(userScope: String? = nil, sync: SyncCoordinator? = nil) {
        self.store = PantryStore(userScope: userScope)
        self.sync = sync
        self.items = Self.sorted(store.all())
        sync?.registerRefreshable(self)
    }

    /// Re-read the pantry from disk after a sync pull wrote new items (the applier
    /// writes straight to `PantryStore`, not this model). Merge-safe: every local
    /// mutation already re-reads `store.all()`, so the store is authoritative —
    /// this adds pulled items and drops nothing added this session.
    func refreshFromStore() {
        items = Self.sorted(store.all())
    }

    /// Newest additions first — the freshest thing you added is at the top.
    private static func sorted(_ items: [PantryItem]) -> [PantryItem] {
        items.sorted { $0.dateAdded > $1.dateAdded }
    }

    /// Add an item, stored EXACTLY as typed (only surrounding whitespace is
    /// trimmed; no normalization). No-op on blank text.
    func add(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let item = PantryItem(name: trimmed)
        store.upsert(item)
        items = Self.sorted(store.all())
        sync?.record(.pantryItems, itemId: item.id.uuidString, payload: SyncCodec.encode(item))
    }

    /// Remove an item ("used it up").
    func remove(_ item: PantryItem) {
        store.remove(id: item.id)
        items = Self.sorted(store.all())
        sync?.record(.pantryItems, itemId: item.id.uuidString, payload: nil, deleted: true)
    }
}
