//
//  RecipeStore.swift
//  RecipeKit
//
//  Durable, on-device cache of completed recipes — the "local caching / offline
//  list" client responsibility (CLAUDE.md §3). Same lightweight pattern as
//  `PendingJobStore` / `MealPlanStore` / `GroceryCheckStore`: a single
//  JSON-encoded `[Recipe]` under one key in the App Group `UserDefaults`.
//
//  Why this exists: the backend is job-oriented and has no "list my vault"
//  endpoint (`RecipeProvider.fetchRecipes` returns []), and a finished job is
//  removed from `PendingJobStore` the moment it completes. Without this store a
//  recipe extracted in a past session would be gone after a full relaunch. This
//  persists it locally so the Recipes list, the Meal Plan picker, and the
//  Grocery List derivation all survive relaunches — independent of whether the
//  backend ever grows a vault endpoint.
//
//  Ordering is carried by array position (newest first), mirroring the in-memory
//  `recipes.insert(_, at: 0)` behavior — so no timestamp field is needed on
//  `Recipe`.
//

import Foundation

public struct RecipeStore {

    /// Key holding the JSON-encoded `[Recipe]`, newest first. Namespaced by
    /// account when a `userScope` is given (Stage 2b), legacy key otherwise.
    private static let baseKey = "recipes_v1"
    private let storageKey: String

    private let defaults: UserDefaults

    /// Production initializer. Falls back to `.standard` if the App Group suite
    /// can't be opened, so the list degrades to app-local rather than crashing.
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

    /// All cached recipes, in stored order (newest first).
    public func all() -> [Recipe] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([Recipe].self, from: data)) ?? []
    }

    // MARK: - Writes

    /// Insert a recipe at the front, or move it there if already present (keyed by
    /// `recipeId`). Mirrors the in-memory "newest first, de-duplicated" behavior.
    public func upsert(_ recipe: Recipe) {
        var recipes = all().filter { $0.recipeId != recipe.recipeId }
        recipes.insert(recipe, at: 0)
        write(recipes)
    }

    /// Remove a recipe by id (for a future delete-recipe feature).
    public func remove(recipeId: String) {
        write(all().filter { $0.recipeId != recipeId })
    }

    private func write(_ recipes: [Recipe]) {
        guard let data = try? JSONEncoder().encode(recipes) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
