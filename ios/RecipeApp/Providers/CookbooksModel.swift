//
//  CookbooksModel.swift
//  RecipeApp
//
//  Observable coordinator for the Cookbooks feature, wrapping `CookbookStore` +
//  `CookbookMembershipStore` (mirrors how `GroceryListModel` wraps its store).
//  Owns the list of cookbooks and mediates membership reads/writes so views can
//  observe changes (grid counts, the detail-view editor) and re-render.
//
//  "All Recipes" is not a stored cookbook — the grid represents it separately.
//

import Foundation
import RecipeKit

@MainActor
final class CookbooksModel: ObservableObject {

    /// User-created cookbooks, newest-created first.
    @Published private(set) var cookbooks: [Cookbook] = []
    /// Bumped on every membership write so views showing counts/membership
    /// recompute (membership itself lives in UserDefaults, not a @Published).
    @Published private(set) var revision = 0

    private let store: CookbookStore
    private let membership: CookbookMembershipStore
    /// Sync hub (nil in previews/unscoped builds → no sync recording).
    private let sync: SyncCoordinator?

    init(userScope: String? = nil, sync: SyncCoordinator? = nil) {
        self.store = CookbookStore(userScope: userScope)
        self.membership = CookbookMembershipStore(userScope: userScope)
        self.sync = sync
        self.cookbooks = store.all()
    }

    // MARK: - Cookbook CRUD

    /// Creates a cookbook from a name (trimmed). No-op on an empty name.
    @discardableResult
    func createCookbook(named name: String) -> Cookbook? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let cookbook = Cookbook(name: trimmed)
        store.upsert(cookbook)
        cookbooks = store.all()
        sync?.record(.cookbook, itemId: cookbook.id, payload: SyncCodec.encode(cookbook))
        return cookbook
    }

    func rename(_ cookbook: Cookbook, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = cookbook
        updated.name = trimmed
        store.upsert(updated)
        cookbooks = store.all()
        sync?.record(.cookbook, itemId: updated.id, payload: SyncCodec.encode(updated))
    }

    func delete(_ cookbook: Cookbook) {
        // Record membership tombstones for the cookbook's links before clearing.
        let recipeIds = membership.recipeIds(inCookbook: cookbook.id)
        store.remove(id: cookbook.id)
        membership.removeCookbook(cookbook.id)
        cookbooks = store.all()
        revision += 1
        sync?.record(.cookbook, itemId: cookbook.id, payload: nil, deleted: true)
        for recipeId in recipeIds {
            recordMembership(cookbookId: cookbook.id, recipeId: recipeId, deleted: true)
        }
    }

    // MARK: - Membership

    /// Recipe ids in a cookbook (for scoping the filtered list).
    func recipeIds(in cookbookId: String) -> Set<String> {
        Set(membership.recipeIds(inCookbook: cookbookId))
    }

    /// How many recipes a cookbook holds (grid card subtitle).
    func recipeCount(in cookbookId: String) -> Int {
        membership.recipeIds(inCookbook: cookbookId).count
    }

    /// Cookbook ids a recipe currently belongs to (detail-view editor).
    func cookbookIds(for recipeId: String) -> Set<String> {
        Set(membership.cookbookIds(forRecipe: recipeId))
    }

    /// Replace the full set of cookbooks a recipe belongs to (editor save).
    func setCookbooks(for recipeId: String, to cookbookIds: Set<String>) {
        let previous = Set(membership.cookbookIds(forRecipe: recipeId))
        membership.setCookbooks(forRecipe: recipeId, to: Array(cookbookIds))
        revision += 1
        // Record only the diffs as per-pair adds/removes.
        for added in cookbookIds.subtracting(previous) {
            recordMembership(cookbookId: added, recipeId: recipeId, deleted: false)
        }
        for removed in previous.subtracting(cookbookIds) {
            recordMembership(cookbookId: removed, recipeId: recipeId, deleted: true)
        }
    }

    private func recordMembership(cookbookId: String, recipeId: String, deleted: Bool) {
        let link = MembershipPayload(cookbookId: cookbookId, recipeId: recipeId)
        sync?.record(.cookbookMembership,
                     itemId: MembershipPayload.itemId(cookbookId: cookbookId, recipeId: recipeId),
                     payload: SyncCodec.encode(link),
                     deleted: deleted)
    }
}
