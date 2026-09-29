//
//  SavedBudgetPlanStore.swift
//  RecipeKit
//
//  Local persistence for the current Plan on a Budget plan, so leaving the screen
//  or closing the app doesn't lose it (a free account only gets one plan). One
//  JSON-encoded `SavedBudgetPlan` per account under `budget_plan_v1_<userId>` in
//  the App Group defaults — same pattern as the other account-scoped stores.
//

import Foundation

/// The plan as last seen (generation response, updated by swaps) plus the request
/// fields the "Your week" header needs.
public struct SavedBudgetPlan: Codable, Equatable {
    public var planId: String?
    public var recipes: [PlannedRecipe]
    public var total: Double
    public var budget: Double
    public var currency: String
    public var swapsRemaining: Int?
    public var isFree: Bool
    // Request fields for the header ("Estimated for … · N people").
    public var householdSize: Int
    public var regionLabel: String?
    public var savedAt: Date

    public init(
        planId: String?, recipes: [PlannedRecipe], total: Double, budget: Double, currency: String = "USD",
        swapsRemaining: Int?, isFree: Bool, householdSize: Int, regionLabel: String?, savedAt: Date = Date()
    ) {
        self.planId = planId
        self.recipes = recipes
        self.total = total
        self.budget = budget
        self.currency = currency
        self.swapsRemaining = swapsRemaining
        self.isFree = isFree
        self.householdSize = householdSize
        self.regionLabel = regionLabel
        self.savedAt = savedAt
    }
}

public struct SavedBudgetPlanStore {
    private static let baseKey = "budget_plan_v1"
    private let storageKey: String
    private let defaults: UserDefaults

    public init(suiteName: String = AppGroup.identifier, userScope: String? = nil) {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
        self.storageKey = scopedStorageKey(Self.baseKey, userScope)
    }

    public init(defaults: UserDefaults, userScope: String? = nil) {
        self.defaults = defaults
        self.storageKey = scopedStorageKey(Self.baseKey, userScope)
    }

    public func load() -> SavedBudgetPlan? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(SavedBudgetPlan.self, from: data)
    }

    public func save(_ plan: SavedBudgetPlan) {
        guard let data = try? JSONEncoder().encode(plan) else { return }
        defaults.set(data, forKey: storageKey)
    }

    public func clear() {
        defaults.removeObject(forKey: storageKey)
    }
}
