//
//  CookbookStore.swift
//  RecipeKit
//
//  Local persistence for user-created cookbooks — a single JSON-encoded
//  `[Cookbook]` under one key, mirroring `MealPlanStore` / `RecipeStore`. Same
//  App Group suite, survives relaunches, no external service, no sync.
//
//  Does NOT store an "All Recipes" entry: that's a synthetic collection the UI
//  always shows, so it can't be renamed or deleted. Membership (which recipes
//  are in which cookbook) lives separately in `CookbookMembershipStore`.
//

import Foundation

public struct CookbookStore {

    /// Single key holding the JSON-encoded `[Cookbook]`, newest-created first.
    private static let baseKey = "cookbooks_v1"
    private let storageKey: String

    private let defaults: UserDefaults

    /// Production initializer. Falls back to `.standard` if the App Group suite
    /// can't be opened, so cookbooks degrade to app-local rather than crashing.
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

    /// All cookbooks, in stored order (newest-created first).
    public func all() -> [Cookbook] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([Cookbook].self, from: data)) ?? []
    }

    // MARK: - Writes

    /// Insert a new cookbook at the front, or replace an existing one (keyed by
    /// `id`) in place — the latter is how a rename persists.
    public func upsert(_ cookbook: Cookbook) {
        var cookbooks = all()
        if let idx = cookbooks.firstIndex(where: { $0.id == cookbook.id }) {
            cookbooks[idx] = cookbook
        } else {
            cookbooks.insert(cookbook, at: 0)
        }
        write(cookbooks)
    }

    /// Remove a cookbook by id. Caller is responsible for also clearing its
    /// membership (see `CookbookMembershipStore.removeCookbook`).
    public func remove(id: String) {
        write(all().filter { $0.id != id })
    }

    private func write(_ cookbooks: [Cookbook]) {
        guard let data = try? JSONEncoder().encode(cookbooks) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
