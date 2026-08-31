//
//  CookbookMembershipStore.swift
//  RecipeKit
//
//  The many-to-many mapping between cookbooks and recipes, kept OUT of the
//  immutable `Recipe` model. Stored cookbook-keyed — a single JSON dict
//  `[cookbookId: [recipeId]]` under one App Group key — because the hot path is
//  "show the recipes in this cookbook" (a folder tap), which is then an O(1)
//  lookup. The reverse ("which cookbooks is this recipe in?") is an O(n) scan
//  over the dict's values, used only by the recipe-detail editor.
//
//  "All Recipes" is intentionally NOT represented here: it's every recipe in
//  `RecipeStore`, independent of membership.
//

import Foundation

public struct CookbookMembershipStore {

    /// Key holding the JSON-encoded `[cookbookId: [recipeId]]`. Namespaced by
    /// account when a `userScope` is given (Stage 2b), legacy key otherwise.
    private static let baseKey = "cookbook_membership_v1"
    private let storageKey: String

    private let defaults: UserDefaults

    /// Production initializer. Falls back to `.standard` if the App Group suite
    /// can't be opened, so membership degrades to app-local rather than crashing.
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

    /// Recipe ids in a cookbook, in insertion order (O(1) key lookup).
    public func recipeIds(inCookbook cookbookId: String) -> [String] {
        map()[cookbookId] ?? []
    }

    /// Cookbook ids a recipe belongs to (O(n) scan over cookbooks).
    public func cookbookIds(forRecipe recipeId: String) -> [String] {
        map().compactMap { key, ids in ids.contains(recipeId) ? key : nil }
    }

    /// Every (cookbook, recipe) link, cookbook-key order. Used by the Stage 4
    /// claim path to enumerate memberships for migration into a signed-in account.
    public func allMemberships() -> [(cookbookId: String, recipeId: String)] {
        map().flatMap { cookbookId, recipeIds in
            recipeIds.map { (cookbookId: cookbookId, recipeId: $0) }
        }
    }

    // MARK: - Writes

    /// Replace the full set of cookbooks a recipe belongs to — the detail-view
    /// editor's save. Adds the recipe to each id in `cookbookIds` and removes it
    /// from every cookbook not listed.
    public func setCookbooks(forRecipe recipeId: String, to cookbookIds: [String]) {
        var m = map()
        let target = Set(cookbookIds)
        for key in Set(m.keys).union(target) {
            var ids = m[key] ?? []
            let has = ids.contains(recipeId)
            if target.contains(key), !has {
                ids.append(recipeId)
            } else if !target.contains(key), has {
                ids.removeAll { $0 == recipeId }
            }
            if ids.isEmpty { m[key] = nil } else { m[key] = ids }
        }
        write(m)
    }

    /// Drop a cookbook's membership entirely (call alongside `CookbookStore.remove`).
    public func removeCookbook(_ cookbookId: String) {
        var m = map()
        m[cookbookId] = nil
        write(m)
    }

    /// Strip a recipe from every cookbook (for a future delete-recipe feature).
    public func removeRecipe(_ recipeId: String) {
        var m = map()
        for (key, ids) in m {
            let filtered = ids.filter { $0 != recipeId }
            if filtered.isEmpty { m[key] = nil } else { m[key] = filtered }
        }
        write(m)
    }

    // MARK: - Storage

    private func map() -> [String: [String]] {
        guard let data = defaults.data(forKey: storageKey) else { return [:] }
        return (try? JSONDecoder().decode([String: [String]].self, from: data)) ?? [:]
    }

    private func write(_ m: [String: [String]]) {
        guard let data = try? JSONEncoder().encode(m) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
