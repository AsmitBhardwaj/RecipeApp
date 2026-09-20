//
//  PaywallPricing.swift
//  RecipeKit
//
//  Pure price math for the paywall, derived entirely from real plan prices —
//  the annual card's "$X/month" figure and the "SAVE N%" pill. No prices are
//  ever hardcoded. Unit-tested in PaywallPricingTests.
//

import Foundation

public enum PaywallPricing {

    /// The annual plan expressed as a per-month amount (annual price ÷ 12).
    public static func monthlyEquivalent(ofAnnual annualPrice: Decimal) -> Decimal {
        annualPrice / 12
    }

    /// Whole-percent saving of the annual plan vs. paying monthly for a year.
    /// Returns nil when there is no saving (annual ≥ 12× monthly), so the caller
    /// hides the pill rather than showing "SAVE 0%" or a negative number.
    public static func savingsPercent(annualPrice: Decimal, monthlyPrice: Decimal) -> Int? {
        let yearAtMonthly = monthlyPrice * 12
        guard yearAtMonthly > 0, annualPrice < yearAtMonthly else { return nil }
        let fraction = (yearAtMonthly - annualPrice) / yearAtMonthly   // 0…1
        let percent = (fraction * 100 as Decimal).rounded()            // nearest whole %
        let value = Int(truncating: percent as NSNumber)
        return value > 0 ? value : nil
    }

    /// Format a `Decimal` as a currency string for the given ISO currency code,
    /// using the current locale's conventions. Used for the annual card's
    /// computed "$X/month" (the store gives no per-month string for an annual
    /// product, so we format the derived value ourselves).
    public static func formatted(_ amount: Decimal, currencyCode: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        return formatter.string(from: amount as NSNumber) ?? "\(amount)"
    }

    /// Convenience: the annual plan's per-month price, already formatted.
    public static func monthlyEquivalentString(forAnnual plan: PaywallPlan) -> String {
        formatted(monthlyEquivalent(ofAnnual: plan.price), currencyCode: plan.currencyCode)
    }
}

private extension Decimal {
    func rounded() -> Decimal {
        var value = self
        var result = Decimal()
        NSDecimalRound(&result, &value, 0, .plain)
        return result
    }
}
