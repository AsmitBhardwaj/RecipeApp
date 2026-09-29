//
//  PlanQuizAnswers.swift
//  RecipeKit
//
//  The value types behind the Plan on a Budget onboarding quiz: food moods,
//  appliances, and the store tiles with their price tiers. Raw values of
//  `FoodMood`, `Appliance` and `StoreTier` are the exact strings the server's
//  request enums accept (app/models.py) — keep them in sync.
//

import Foundation

/// A soft steer on what kind of dinners to propose (max 3).
public enum FoodMood: String, Codable, CaseIterable, Hashable, Sendable {
    case comfort
    case lightFresh = "light_fresh"
    case spicy
    case quick
    case adventurous
    case highProtein = "high_protein"

    public static let maxSelection = 3

    public var title: String {
        switch self {
        case .comfort: "Comfort food"
        case .lightFresh: "Light & fresh"
        case .spicy: "Spicy"
        case .quick: "Quick"
        case .adventurous: "Adventurous"
        case .highProtein: "High-protein"
        }
    }

    public var blurb: String {
        switch self {
        case .comfort: "Warm, hearty, familiar"
        case .lightFresh: "Bright, veg-forward"
        case .spicy: "Bring the heat"
        case .quick: "Under 30 minutes"
        case .adventurous: "Try new cuisines"
        case .highProtein: "Keeps you full"
        }
    }

    /// Asset-catalog name for the card image (`mood_comfort`, `mood_light_fresh`, …).
    public var assetName: String { "mood_\(rawValue)" }

    var sortIndex: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// Cooking equipment — a HARD constraint on generation (every dinner may only
/// use what the user has).
public enum Appliance: String, Codable, CaseIterable, Hashable, Sendable {
    case stovetop
    case oven
    case microwave
    case airFryer = "air_fryer"
    case slowCooker = "slow_cooker"
    case riceCooker = "rice_cooker"
    case blender
    case kettle

    public var title: String { BudgetEquipment.label(for: rawValue) }
}

/// How pricey the user's usual stores are; sent as `store_tier`.
public enum StoreTier: String, Codable, CaseIterable, Hashable, Sendable {
    case budget
    case standard
    case premium
}

/// One store tile on the Store screen. Text only (no logos) with a `$` hint.
public struct PlanStore: Hashable, Sendable {
    public let name: String
    public let priceHint: String
    public let tier: StoreTier

    public init(name: String, priceHint: String, tier: StoreTier) {
        self.name = name
        self.priceHint = priceHint
        self.tier = tier
    }

    public static let otherName = "Other"

    /// Row-major order of the 3×3 grid.
    public static let all: [PlanStore] = [
        PlanStore(name: "Aldi", priceHint: "$", tier: .budget),
        PlanStore(name: "Walmart", priceHint: "$", tier: .budget),
        PlanStore(name: "Lidl", priceHint: "$", tier: .budget),
        PlanStore(name: "Kroger", priceHint: "$$", tier: .standard),
        PlanStore(name: "Target", priceHint: "$$", tier: .standard),
        PlanStore(name: "Trader Joe's", priceHint: "$$", tier: .standard),
        PlanStore(name: "Costco", priceHint: "$$", tier: .standard),
        PlanStore(name: "Whole Foods", priceHint: "$$$", tier: .premium),
        PlanStore(name: otherName, priceHint: "", tier: .standard),
    ]

    public static func named(_ name: String) -> PlanStore? {
        all.first { $0.name == name }
    }

    /// Tier for a stored store name; an unknown name is treated like "Other".
    public static func tier(forStoreName name: String) -> StoreTier {
        named(name)?.tier ?? .standard
    }

    /// The name used in "Estimated for <store> shoppers"; nil for "Other" (there
    /// is no store to name).
    public var shopperLabel: String? { name == Self.otherName ? nil : name }

    /// The name used in the budget helper card ("… at <store> usually spend …").
    public var helperName: String { shopperLabel ?? "your store" }

    /// VoiceOver text: "Aldi, budget prices".
    public var accessibilityText: String {
        switch (name == Self.otherName, tier) {
        case (true, _): return "Other store"
        case (_, .budget): return "\(name), budget prices"
        case (_, .standard): return "\(name), mid-range prices"
        case (_, .premium): return "\(name), premium prices"
        }
    }
}
