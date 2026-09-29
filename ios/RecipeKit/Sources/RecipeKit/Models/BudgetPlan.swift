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

/// Pexels attribution for a meal's stock photo. Every field is optional so a
/// partial payload still decodes.
public struct PhotoCredit: Codable, Hashable, Sendable {
    public let photographer: String?
    public let photographerUrl: String?
    public let pexelsUrl: String?

    public init(photographer: String? = nil, photographerUrl: String? = nil, pexelsUrl: String? = nil) {
        self.photographer = photographer
        self.photographerUrl = photographerUrl
        self.pexelsUrl = pexelsUrl
    }

    enum CodingKeys: String, CodingKey {
        case photographer
        case photographerUrl = "photographer_url"
        case pexelsUrl = "pexels_url"
    }
}

/// One recipe in a budget plan: the recipe body plus its per-user estimated cost
/// and a short health signal.
public struct PlannedRecipe: Codable, Identifiable, Hashable {
    public let recipe: Recipe
    public let estimatedCost: CostEstimate
    public let healthSignal: String
    /// Raw equipment values the dinner needs (`stovetop`, …, or `no_cook`). Absent
    /// from a v1.0 server response, so it decodes to `[]`. Use `equipmentLabels`
    /// for display — `no_cook` is never an appliance.
    public let equipmentUsed: [String]
    public var id: String { recipe.recipeId }

    public init(recipe: Recipe, estimatedCost: CostEstimate, healthSignal: String, equipmentUsed: [String] = []) {
        self.recipe = recipe
        self.estimatedCost = estimatedCost
        self.healthSignal = healthSignal
        self.equipmentUsed = equipmentUsed
    }

    enum CodingKeys: String, CodingKey {
        case recipe
        case estimatedCost = "estimated_cost"
        case healthSignal = "health_signal"
        case equipmentUsed = "equipment_used"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recipe = try c.decode(Recipe.self, forKey: .recipe)
        estimatedCost = try c.decode(CostEstimate.self, forKey: .estimatedCost)
        healthSignal = try c.decodeIfPresent(String.self, forKey: .healthSignal) ?? ""
        equipmentUsed = try c.decodeIfPresent([String].self, forKey: .equipmentUsed) ?? []
    }

    /// The meal's stock photo. The server puts `image_url` / `photo_credit` on the
    /// recipe itself (single source of truth); nil for plans generated before photos.
    public var photoURL: String? {
        recipe.imageUrl.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Pexels credit for `photoURL`, when the server supplied one.
    public var photoCredit: PhotoCredit? { recipe.photoCredit }

    /// Display labels for `equipmentUsed`, de-duplicated and in server order.
    public var equipmentLabels: [String] { BudgetEquipment.labels(for: equipmentUsed) }

    /// "No cooking", or the appliance names joined by " + " (empty when unknown).
    public var equipmentSummary: String { BudgetEquipment.summary(for: equipmentUsed) }
}

/// Display rules for the server's `equipment_used` values.
public enum BudgetEquipment {
    public static let noCook = "no_cook"

    public static func label(for raw: String) -> String {
        switch raw {
        case noCook: return "No cooking"
        case "stovetop": return "Stovetop"
        case "oven": return "Oven"
        case "microwave": return "Microwave"
        case "air_fryer": return "Air fryer"
        case "slow_cooker": return "Slow cooker"
        case "rice_cooker": return "Rice cooker"
        case "blender": return "Blender"
        case "kettle": return "Kettle"
        default:
            let words = raw.replacingOccurrences(of: "_", with: " ")
            return words.prefix(1).uppercased() + words.dropFirst()
        }
    }

    /// `no_cook` alongside real appliances is dropped (it can't be both); a lone
    /// `no_cook` renders as "No cooking".
    public static func labels(for raw: [String]) -> [String] {
        var seen = Set<String>()
        let unique = raw.filter { seen.insert($0).inserted }
        let appliances = unique.filter { $0 != noCook }
        if appliances.isEmpty { return unique.isEmpty ? [] : [label(for: noCook)] }
        return appliances.map(label(for:))
    }

    public static func summary(for raw: [String]) -> String {
        labels(for: raw).joined(separator: " + ")
    }
}

public struct BudgetPlanResponse: Codable {
    public let recipes: [PlannedRecipe]
    public let currency: String
    public let budget: Double
    public let minBudget: Int
    public let regionalMultiplier: Double
    /// Ledger id for the swap endpoint (nil from a v1.0 server).
    public let planId: String?
    /// True when this plan consumed the account's one free plan.
    public let isFree: Bool
    /// Swaps left on this plan; nil = unlimited (Pro). Always server-supplied —
    /// the client never counts swaps.
    public let swapsRemaining: Int?

    public init(
        recipes: [PlannedRecipe], currency: String, budget: Double, minBudget: Int, regionalMultiplier: Double,
        planId: String? = nil, isFree: Bool = false, swapsRemaining: Int? = nil
    ) {
        self.recipes = recipes
        self.currency = currency
        self.budget = budget
        self.minBudget = minBudget
        self.regionalMultiplier = regionalMultiplier
        self.planId = planId
        self.isFree = isFree
        self.swapsRemaining = swapsRemaining
    }

    enum CodingKeys: String, CodingKey {
        case recipes, currency, budget
        case minBudget = "min_budget"
        case regionalMultiplier = "regional_multiplier"
        case planId = "plan_id"
        case isFree = "is_free"
        case swapsRemaining = "swaps_remaining"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recipes = try c.decode([PlannedRecipe].self, forKey: .recipes)
        currency = try c.decode(String.self, forKey: .currency)
        budget = try c.decode(Double.self, forKey: .budget)
        minBudget = try c.decode(Int.self, forKey: .minBudget)
        regionalMultiplier = try c.decode(Double.self, forKey: .regionalMultiplier)
        planId = try c.decodeIfPresent(String.self, forKey: .planId)
        isFree = try c.decodeIfPresent(Bool.self, forKey: .isFree) ?? false
        swapsRemaining = try c.decodeIfPresent(Int.self, forKey: .swapsRemaining)
    }

    /// Sum of the dinners' estimated costs (the plan total before any swap).
    public var total: Double { recipes.reduce(0) { $0 + $1.estimatedCost.amount } }
}

/// POST /v1/meal-plan/budget/{plan_id}/swap
public struct BudgetSwapResponse: Codable {
    public let planId: String
    public let mealIndex: Int
    public let meal: PlannedRecipe
    public let planTotal: Double
    public let currency: String
    public let budget: Double
    public let swapsUsed: Int
    public let swapsRemaining: Int?

    public init(
        planId: String, mealIndex: Int, meal: PlannedRecipe, planTotal: Double,
        currency: String = "USD", budget: Double, swapsUsed: Int, swapsRemaining: Int?
    ) {
        self.planId = planId
        self.mealIndex = mealIndex
        self.meal = meal
        self.planTotal = planTotal
        self.currency = currency
        self.budget = budget
        self.swapsUsed = swapsUsed
        self.swapsRemaining = swapsRemaining
    }

    enum CodingKeys: String, CodingKey {
        case meal, currency, budget
        case planId = "plan_id"
        case mealIndex = "meal_index"
        case planTotal = "plan_total"
        case swapsUsed = "swaps_used"
        case swapsRemaining = "swaps_remaining"
    }
}

/// Optional v1.1 request fields. Each is sent only when set, so an unconfigured
/// request stays v1.0-shaped.
public struct BudgetPlanOptions: Equatable, Sendable {
    public var storeTier: String?
    public var appliances: [String]?
    public var foodMoods: [String]?

    public init(storeTier: String? = nil, appliances: [String]? = nil, foodMoods: [String]? = nil) {
        self.storeTier = storeTier
        self.appliances = appliances
        self.foodMoods = foodMoods
    }

    public static let none = BudgetPlanOptions()
}

/// Typed failures the budget-plan endpoint can surface, each mapping to a
/// distinct thing the UI shows.
public enum BudgetPlanError: Error, Equatable {
    /// 403 — the server rejected a non-Pro caller. The UI shows the paywall.
    case proRequired
    /// 403 pro_required with reason "free_plan_used" — the free plan is spent.
    /// Also opens the paywall; kept distinct so Stage 3 can tailor the copy.
    case freePlanUsed
    /// 402 free_swaps_used — this free plan is out of swaps. Opens the paywall.
    case freeSwapsUsed
    /// 409 plan_changed — a concurrent swap won; retry once.
    case planChanged
    /// 502 swap_constraint_unmet / appliance_constraint_unmet — nothing was
    /// consumed; the user can just try again.
    case constraintUnmet
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
        case .proRequired, .freePlanUsed:
            return "Plan on a Budget is a Platter Pro feature."
        case .freeSwapsUsed:
            return "You've used your free swaps for this plan."
        case .planChanged:
            return "This plan just changed. Please try again."
        case .constraintUnmet:
            return "Couldn't find a swap that fits — try again."
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
