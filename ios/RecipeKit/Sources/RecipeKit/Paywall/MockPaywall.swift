//
//  MockPaywall.swift
//  RecipeKit
//
//  In-memory stand-ins for the paywall's dependencies, with switchable
//  scenarios. Used by SwiftUI previews and unit tests until the real RevenueCat
//  / EntitlementManager implementations land (see docs/PAYWALL_WIRING.md).
//
//  NOTE: the sample prices here are the MOCK "store" — the rule "never hardcode
//  prices" applies to the UI, which must read whatever the store returns. These
//  mock values stand in for that store so previews/tests have data.
//

import Foundation

/// Switchable behaviors for `MockPaywallPurchasing`.
public enum PaywallMockScenario: Equatable {
    case trialEligible
    case notTrialEligible
    case purchaseFails
    case purchaseCancelled
    case restoreNothing
    case slowLoad
    case loadFailure

    var isTrialEligible: Bool { self != .notTrialEligible }
}

@MainActor
public final class MockEntitlementProvider: EntitlementProviding {
    public var isPro: Bool
    public let freeImportLimit: Int
    public var freeImportsRemaining: Int

    public nonisolated init(isPro: Bool = false, freeImportLimit: Int = 10, freeImportsRemaining: Int = 0) {
        self.isPro = isPro
        self.freeImportLimit = freeImportLimit
        self.freeImportsRemaining = freeImportsRemaining
    }

    public func refresh() async { /* no-op in the mock */ }
}

@MainActor
public final class MockPaywallPurchasing: PaywallPurchasing {
    public var scenario: PaywallMockScenario
    /// Sample "store" prices (USD). Stand in for the real offering.
    private let annualPrice: Decimal
    private let monthlyPrice: Decimal
    private let currency: String

    public nonisolated init(
        scenario: PaywallMockScenario = .trialEligible,
        annualPrice: Decimal = 39.99,
        monthlyPrice: Decimal = 4.99,
        currency: String = "USD"
    ) {
        self.scenario = scenario
        self.annualPrice = annualPrice
        self.monthlyPrice = monthlyPrice
        self.currency = currency
    }

    public func loadOffering() async throws -> PaywallOffering {
        if scenario == .slowLoad {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        if scenario == .loadFailure {
            throw PaywallError.loadFailed
        }
        let annual = PaywallPlan(
            id: PaywallProductID.annual,
            localizedPrice: PaywallPricing.formatted(annualPrice, currencyCode: currency),
            price: annualPrice,
            currencyCode: currency,
            period: .annual,
            introTrialDays: 7,
            isTrialEligible: scenario.isTrialEligible
        )
        let monthly = PaywallPlan(
            id: PaywallProductID.monthly,
            localizedPrice: PaywallPricing.formatted(monthlyPrice, currencyCode: currency),
            price: monthlyPrice,
            currencyCode: currency,
            period: .monthly,
            introTrialDays: nil,          // no trial on monthly
            isTrialEligible: false
        )
        return PaywallOffering(annual: annual, monthly: monthly)
    }

    public func purchase(_ plan: PaywallPlan) async throws -> PurchaseOutcome {
        try? await Task.sleep(nanoseconds: 400_000_000)   // simulate the store round-trip
        switch scenario {
        case .purchaseCancelled: return .cancelled
        case .purchaseFails: throw PaywallError.purchaseFailed("The purchase could not be completed.")
        default: return .success
        }
    }

    public func restore() async throws -> RestoreOutcome {
        try? await Task.sleep(nanoseconds: 400_000_000)
        switch scenario {
        case .restoreNothing: return .nothingToRestore
        default: return .restored
        }
    }
}
