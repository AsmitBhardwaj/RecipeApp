//
//  BudgetMath.swift
//  RecipeKit
//
//  The per-person minimum weekly budget for Plan on a Budget. Mirrors the server
//  (app/budget.py + config.MIN_BUDGET_PER_PERSON) EXACTLY so the client stepper
//  floor and caption match what the backend enforces. Keep the constant and the
//  rounding rule in sync with the backend.
//

import Foundation

public enum BudgetMath {
    /// PLACEHOLDER — mirror of backend `config.MIN_BUDGET_PER_PERSON`.
    public static let minBudgetPerPerson = 25
    private static let increment = 5

    private static func roundToIncrement(_ value: Int) -> Int {
        Int((Double(value) / Double(increment)).rounded()) * increment
    }

    /// Minimum allowed weekly budget for a household, scaled per person and
    /// rounded to the nearest $5. Household size is clamped to at least 1.
    public static func minBudget(householdSize: Int) -> Int {
        roundToIncrement(max(1, householdSize) * minBudgetPerPerson)
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
