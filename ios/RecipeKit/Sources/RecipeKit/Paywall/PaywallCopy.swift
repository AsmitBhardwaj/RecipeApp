//
//  PaywallCopy.swift
//  RecipeKit
//
//  All paywall copy, as pure functions of (trigger, offering, selected plan,
//  eligibility, free-import limit). Kept here — not in the View — so the
//  trigger→copy mapping, CTA text, and fine print are unit-tested without UI.
//  Prices are always taken from the passed-in plan data, never hardcoded.
//

import Foundation

public enum PaywallCopy {

    // The three canonical benefit lines.
    public enum Benefit {
        public static let unlimited = "Unlimited recipe imports"
        public static let pantry = "Recipes you can make with what's in your pantry"
        public static let macros = "Estimated calories and macros on every recipe"
    }

    // MARK: Headline / subhead / benefits (per trigger)

    public static func headline(for trigger: PaywallTrigger) -> String {
        switch trigger {
        case .importLimit, .settings:
            return "Keep your cookbook growing."
        case .pantry:
            return "Cook with what you've got."
        }
    }

    /// `freeImportLimit` is only used by the importLimit trigger; the settings
    /// trigger deliberately omits the free-count, and pantry has its own line.
    public static func subhead(for trigger: PaywallTrigger, freeImportLimit: Int) -> String {
        switch trigger {
        case .importLimit:
            return "You've used your \(freeImportLimit) free recipes. Platter Pro removes the limit."
        case .pantry:
            return "Pantry suggestions are part of Platter Pro. Add your ingredients and find something to make tonight."
        case .settings:
            return "Get the most out of Platter."
        }
    }

    /// Benefit rows, ordered so the trigger's most relevant benefit leads.
    public static func benefits(for trigger: PaywallTrigger) -> [String] {
        switch trigger {
        case .importLimit, .settings:
            return [Benefit.unlimited, Benefit.pantry, Benefit.macros]
        case .pantry:
            return [Benefit.pantry, Benefit.unlimited, Benefit.macros]
        }
    }

    // MARK: Trial eligibility

    /// The annual plan offers a trial to this user (has intro days AND is eligible).
    public static func annualTrialEligible(_ offering: PaywallOffering) -> Bool {
        (offering.annual.introTrialDays ?? 0) > 0 && offering.annual.isTrialEligible
    }

    // MARK: Plan-card subtitles

    /// Annual card subtitle: "7 days free, then $X/month" when trial-eligible,
    /// otherwise just "$X/month" (the trial line is hidden).
    public static func annualCardSubtitle(_ offering: PaywallOffering) -> String {
        let perMonth = PaywallPricing.monthlyEquivalentString(forAnnual: offering.annual)
        if annualTrialEligible(offering), let days = offering.annual.introTrialDays {
            return "\(days) days free, then \(perMonth)/month"
        }
        return "\(perMonth)/month"
    }

    public static func monthlyCardSubtitle() -> String { "Billed monthly" }

    // MARK: CTA

    /// Primary CTA label for the selected plan.
    ///  - annual + eligible → "Start 7-day free trial"
    ///  - annual + not eligible → "Subscribe for $Y/year"
    ///  - monthly → "Subscribe for $Z/month" (never a trial)
    public static func ctaTitle(selectedPeriod: PaywallPeriod, offering: PaywallOffering) -> String {
        switch selectedPeriod {
        case .annual:
            if annualTrialEligible(offering), let days = offering.annual.introTrialDays {
                return "Start \(days)-day free trial"
            }
            return "Subscribe for \(offering.annual.localizedPrice)/year"
        case .monthly:
            return "Subscribe for \(offering.monthly.localizedPrice)/month"
        }
    }

    // MARK: Fine print

    /// Legal fine print under the CTA, adapting to the selected plan + eligibility.
    public static func finePrint(selectedPeriod: PaywallPeriod, offering: PaywallOffering) -> String {
        let tail = "Renews automatically. Cancel anytime in Settings."
        switch selectedPeriod {
        case .annual:
            let price = offering.annual.localizedPrice
            if annualTrialEligible(offering), let days = offering.annual.introTrialDays {
                return "\(days) days free, then \(price) per year. \(tail)"
            }
            return "\(price) per year. \(tail)"
        case .monthly:
            return "\(offering.monthly.localizedPrice) per month. \(tail)"
        }
    }
}
