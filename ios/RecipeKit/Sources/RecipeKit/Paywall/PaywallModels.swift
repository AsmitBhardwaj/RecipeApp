//
//  PaywallModels.swift
//  RecipeKit
//
//  The value types the Platter Pro paywall UI is built on. These (plus the
//  protocols in PaywallProtocols.swift) are the CONTRACT: the real RevenueCat +
//  EntitlementManager implementation conforms to the protocols and vends these
//  structs, so no RevenueCat type ever reaches the UI layer. See
//  docs/PAYWALL_WIRING.md.
//

import Foundation

/// The App Store product identifiers for the two Platter Pro subscriptions.
public enum PaywallProductID {
    public static let annual = "platter_pro_annual"
    public static let monthly = "platter_pro_monthly"
}

/// Which surface triggered the paywall — drives the headline / subhead / the
/// order of the benefit rows.
public enum PaywallTrigger: Equatable, CaseIterable {
    case importLimit
    case pantry
    case settings
}

/// A subscription billing period.
public enum PaywallPeriod: Equatable {
    case monthly
    case annual
}

/// One purchasable plan, already localized. Prices are the store's real,
/// locale-formatted values — never hardcoded.
public struct PaywallPlan: Identifiable, Equatable {
    public let id: String                 // product id
    public let localizedPrice: String     // e.g. "$39.99" (store-formatted)
    public let price: Decimal             // numeric, for math
    public let currencyCode: String       // e.g. "USD"
    public let period: PaywallPeriod
    public let introTrialDays: Int?       // e.g. 7, or nil if no intro offer
    public let isTrialEligible: Bool      // this user's intro-offer eligibility

    public init(
        id: String,
        localizedPrice: String,
        price: Decimal,
        currencyCode: String,
        period: PaywallPeriod,
        introTrialDays: Int?,
        isTrialEligible: Bool
    ) {
        self.id = id
        self.localizedPrice = localizedPrice
        self.price = price
        self.currencyCode = currencyCode
        self.period = period
        self.introTrialDays = introTrialDays
        self.isTrialEligible = isTrialEligible
    }
}

/// The current offering: exactly the annual + monthly packages.
public struct PaywallOffering: Equatable {
    public let annual: PaywallPlan
    public let monthly: PaywallPlan

    public init(annual: PaywallPlan, monthly: PaywallPlan) {
        self.annual = annual
        self.monthly = monthly
    }

    public func plan(for period: PaywallPeriod) -> PaywallPlan {
        period == .annual ? annual : monthly
    }
}

/// Result of a purchase attempt. A user-initiated cancellation is a normal,
/// non-error outcome (the UI stays put, shows nothing).
public enum PurchaseOutcome: Equatable {
    case success
    case cancelled
}

/// Result of a restore attempt.
public enum RestoreOutcome: Equatable {
    case restored
    case nothingToRestore
}

/// Errors the purchasing layer can surface to the UI (network/store failures).
/// Cancellation is NOT an error — it's `PurchaseOutcome.cancelled`.
public enum PaywallError: Error, Equatable {
    case loadFailed
    case purchaseFailed(String)
    case restoreFailed(String)
}
