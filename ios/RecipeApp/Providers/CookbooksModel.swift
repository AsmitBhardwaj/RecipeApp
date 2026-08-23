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

    init(store: CookbookStore = CookbookStore(),
         membership: CookbookMembershipStore = CookbookMembershipStore()) {
        self.store = store
        self.membership = membership
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
        return cookbook
    }

    func rename(_ cookbook: Cookbook, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = cookbook
        updated.name = trimmed
        store.upsert(updated)
        cookbooks = store.all()
    }

    func delete(_ cookbook: Cookbook) {
        store.remove(id: cookbook.id)
        membership.removeCookbook(cookbook.id)
        cookbooks = store.all()
        revision += 1
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
        membership.setCookbooks(forRecipe: recipeId, to: Array(cookbookIds))
        revision += 1
    }
}
