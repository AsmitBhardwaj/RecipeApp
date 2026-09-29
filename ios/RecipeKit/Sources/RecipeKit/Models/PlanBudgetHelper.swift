//
//  PlanBudgetHelper.swift
//  RecipeKit
//
//  The Budget screen's math, plus a client mirror of the server's regional cost
//  multiplier (app/pipeline/regional_cost.py). The server stays authoritative —
//  it converts the budget to baseline space (÷ multiplier) and enforces
//  `BudgetMath` bounds there — so this only sizes the slider and the "people
//  usually spend" hint. Keep the tables in sync with regional_cost.py.
//

import Foundation

/// Mirror of `multiplier_for(country, area_type, store_tier)` for the store-tier
/// path: country baseline × store-tier modifier, rounded to two decimals.
public enum RegionalCostMultiplier {
    static let countryBaselines: [String: Double] = [
        "US": 1.00, "CA": 1.05, "GB": 1.10, "IE": 1.10, "AU": 1.15, "NZ": 1.10, "CH": 1.45, "NO": 1.35,
        "SE": 1.10, "DE": 1.00, "FR": 1.05, "NL": 1.05, "ES": 0.90, "IT": 0.95, "MX": 0.70, "IN": 0.55,
    ]
    static let tierModifiers: [StoreTier: Double] = [.budget: 0.85, .standard: 1.00, .premium: 1.30]

    public static func multiplier(country: String?, storeTier: StoreTier?) -> Double {
        let baseline = country.flatMap { countryBaselines[$0.trimmingCharacters(in: .whitespaces).uppercased()] } ?? 1.0
        let tier = storeTier.flatMap { tierModifiers[$0] } ?? 1.0
        return (baseline * tier * 100).rounded() / 100
    }
}

public enum PlanBudgetHelper {
    public struct TypicalSpend: Equatable, Sendable {
        public let low: Int
        public let high: Int
    }

    public static let increment = 5
    /// Typical dinner cost per person, before the regional multiplier.
    public static let lowPerPersonDinner = 5.5
    public static let highPerPersonDinner = 8.0
    public static let dinnersPerWeek = 7

    static func roundToIncrement(_ value: Double) -> Int {
        Int((value / Double(increment)).rounded()) * increment
    }

    /// "People cooking for N usually spend about $low–$high a week on dinners":
    /// $5.50 and $8 per person per dinner × 7 × people × multiplier, nearest $5.
    public static func typicalSpend(people: Int, multiplier: Double) -> TypicalSpend {
        let n = Double(max(1, people))
        let week = Double(dinnersPerWeek)
        return TypicalSpend(
            low: roundToIncrement(lowPerPersonDinner * week * n * multiplier),
            high: roundToIncrement(highPerPersonDinner * week * n * multiplier)
        )
    }

    /// The slider range: `BudgetMath`'s household bounds scaled by the multiplier
    /// (the server checks budget ÷ multiplier against them), kept on $5 steps and
    /// never wider than the server allows.
    public static func bounds(people: Int, multiplier: Double) -> ClosedRange<Int> {
        let m = max(multiplier, 0.01)
        let lo = BudgetMath.minBudget(householdSize: people, multiplier: m)
        let hi = BudgetMath.maxBudget(householdSize: people, multiplier: m)
        return lo...max(lo, hi)
    }

    /// The default budget: the typical low end, clamped to the bounds.
    public static func defaultBudget(people: Int, multiplier: Double) -> Int {
        clamp(typicalSpend(people: people, multiplier: multiplier).low, people: people, multiplier: multiplier)
    }

    /// Clamps to the bounds and snaps to a $5 step.
    public static func snapped(_ value: Int, people: Int, multiplier: Double) -> Int {
        clamp(roundToIncrement(Double(value)), people: people, multiplier: multiplier)
    }

    static func clamp(_ value: Int, people: Int, multiplier: Double) -> Int {
        let range = bounds(people: people, multiplier: multiplier)
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// "People cooking for 2 at Aldi usually spend about $75–$110 a week on dinners"
    public static func helperText(people: Int, storeName: String, spend: TypicalSpend) -> String {
        "People cooking for \(people) at \(storeName) usually spend about $\(spend.low)–$\(spend.high) a week on dinners"
    }
}
