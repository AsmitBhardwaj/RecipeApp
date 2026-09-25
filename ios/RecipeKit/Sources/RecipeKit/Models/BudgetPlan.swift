//
//  BudgetPlan.swift
//  RecipeKit
//
//  API shapes for Plan on a Budget (POST /v1/meal-plan/budget) plus the pure
//  accept/save selection logic. Codable with explicit snake_case CodingKeys, like
//  the other API models here.
//

import Foundation

/// A labeled cost estimate (never store-accurate).
public struct CostEstimate: Codable, Hashable, Sendable {
    public let amount: Double
    public let currency: String
    public let basis: String

    public init(amount: Double, currency: String = "USD", basis: String = "llm-v1") {
        self.amount = amount
        self.currency = currency
        self.basis = basis
    }
}

/// One recipe in a budget plan: the recipe body plus its per-user estimated cost
/// and a short health signal.
public struct PlannedRecipe: Codable, Identifiable, Hashable {
    public let recipe: Recipe
    public let estimatedCost: CostEstimate
    public let healthSignal: String

    public var id: String { recipe.recipeId }

    public init(recipe: Recipe, estimatedCost: CostEstimate, healthSignal: String) {
        self.recipe = recipe
        self.estimatedCost = estimatedCost
        self.healthSignal = healthSignal
    }

    enum CodingKeys: String, CodingKey {
        case recipe
        case estimatedCost = "estimated_cost"
        case healthSignal = "health_signal"
    }
}

public struct BudgetPlanResponse: Codable {
    public let recipes: [PlannedRecipe]
    public let currency: String
    public let budget: Double
    public let minBudget: Int
    public let regionalMultiplier: Double

    public init(recipes: [PlannedRecipe], currency: String, budget: Double, minBudget: Int, regionalMultiplier: Double) {
        self.recipes = recipes
        self.currency = currency
        self.budget = budget
        self.minBudget = minBudget
        self.regionalMultiplier = regionalMultiplier
    }

    enum CodingKeys: String, CodingKey {
        case recipes, currency, budget
        case minBudget = "min_budget"
        case regionalMultiplier = "regional_multiplier"
    }
}

/// Typed failures the budget-plan endpoint can surface, each mapping to a
/// distinct thing the UI shows.
public enum BudgetPlanError: Error, Equatable {
    /// 403 — the server rejected a non-Pro caller. The UI shows the paywall.
    case proRequired
    /// 400 — budget below the per-person minimum; carries the server's minimum so
    /// the client can correct the stepper.
    case belowMinimum(minBudget: Int)
    /// 400 — budget above the per-person maximum; carries the server's maximum.
    /// Surfaced as a clear error (no silent clamp) so the user lowers it.
    case aboveMaximum(maxBudget: Int)
    /// 429 — the hard per-account 30-day spend cap (backend code
    /// "spend_cap_reached"). Distinct from a generic `http(429)` so the UI shows
    /// the shared "this month's usage limit" message, same as import/paste/pantry.
    case spendCapReached
    case offline
    case timedOut
    case network(String)
    case http(Int)
    case invalidResponse(String)

    public var userMessage: String {
        switch self {
        case .proRequired:
            return "Plan on a Budget is a Platter Pro feature."
        case .spendCapReached:
            return RecipeProviderError.spendCapMessage
        case .belowMinimum(let minBudget):
            return "That budget is below the minimum of $\(minBudget) for your household size."
        case .aboveMaximum(let maxBudget):
            return "That budget is above the maximum of $\(maxBudget) for your household size."
        case .offline:
            return "You appear to be offline. Check your connection and try again."
        case .timedOut:
            return "This is taking longer than expected. Please try again."
        case .network, .http, .invalidResponse:
            return "We couldn't build a plan right now. Please try again."
        }
    }
}

/// Pure accept/save selection for a generated plan. Defaults to ALL recipes
/// accepted; the user toggles individual recipes off. Kept free of SwiftUI so the
/// accept/save math is unit-testable.
public struct BudgetPlanSelection: Equatable, Sendable {
    public private(set) var acceptedIDs: Set<String>

    /// Start with every generated recipe accepted.
    public init(recipes: [PlannedRecipe]) {
        acceptedIDs = Set(recipes.map(\.id))
    }

    public func isAccepted(_ id: String) -> Bool { acceptedIDs.contains(id) }

    public mutating func toggle(_ id: String) {
        if acceptedIDs.contains(id) { acceptedIDs.remove(id) } else { acceptedIDs.insert(id) }
    }

    /// The recipes currently toggled on, in the plan's original order.
    public func accepted(from recipes: [PlannedRecipe]) -> [PlannedRecipe] {
        recipes.filter { acceptedIDs.contains($0.id) }
    }

    public var acceptedCount: Int { acceptedIDs.count }

    /// Total estimated cost of the accepted recipes.
    public func totalCost(from recipes: [PlannedRecipe]) -> Double {
        accepted(from: recipes).reduce(0) { $0 + $1.estimatedCost.amount }
    }
}
