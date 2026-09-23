//
//  BudgetMath.swift
//  RecipeKit
//
//  The per-person weekly budget bounds for Plan on a Budget. These mirror the
//  server's derived model (app/budget.py) as an APPROXIMATE, region-agnostic
//  stepper hint — nominal = per-person baseline anchors:
//      minBudgetPerPerson = per_dinner_floor    ($3) × min_recipe_count (4) = $12
//      maxBudgetPerPerson = per_dinner_ceiling  ($12) × max_recipe_count (7) = $84
//  The server is authoritative and enforces both bounds AFTER converting the
//  budget into baseline space (÷ regional multiplier), so for a non-1.0× region
//  the true bound differs; keep these anchors in sync with app/budget.py.
//

import Foundation

public enum BudgetMath {
    /// Nominal per-person floor = per_dinner_floor × min_recipe_count (baseline).
    public static let minBudgetPerPerson = 12
    /// Nominal per-person cap = per_dinner_richness_ceiling × max_recipe_count.
    public static let maxBudgetPerPerson = 84
    private static let increment = 5

    private static func roundToIncrement(_ value: Int) -> Int {
        Int((Double(value) / Double(increment)).rounded()) * increment
    }

    /// Minimum allowed weekly budget for a household, scaled per person and
    /// rounded to the nearest $5. Household size is clamped to at least 1.
    public static func minBudget(householdSize: Int) -> Int {
        roundToIncrement(max(1, householdSize) * minBudgetPerPerson)
    }

    /// Maximum allowed weekly budget for a household (nominal hint), scaled per
    /// person and rounded to the nearest $5. Household size clamped to ≥ 1.
    public static func maxBudget(householdSize: Int) -> Int {
        roundToIncrement(max(1, householdSize) * maxBudgetPerPerson)
    }

    /// Reconcile a budget against a (possibly new) household size: raise it to the
    /// minimum if it's below, but NEVER lower it — a user who chose to spend more
    /// keeps that choice when household size drops.
    public static func reconciled(currentBudget: Int, householdSize: Int) -> Int {
        max(currentBudget, minBudget(householdSize: householdSize))
    }

    /// Caption under the stepper, e.g. "$50 minimum for 2 people".
    public static func minimumCaption(householdSize: Int) -> String {
        let people = householdSize == 1 ? "1 person" : "\(householdSize) people"
        return "$\(minBudget(householdSize: householdSize)) minimum for \(people)"
    }
}
