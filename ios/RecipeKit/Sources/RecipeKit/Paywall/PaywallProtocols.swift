//
//  PaywallProtocols.swift
//  RecipeKit
//
//  The paywall's dependency contract. The real implementations
//  (EntitlementManager over RevenueCat/StoreKit) land on `feature/pro-
//  entitlements` and conform to these — the UI depends only on these protocols,
//  never on RevenueCat. See docs/PAYWALL_WIRING.md.
//

import Foundation

/// The app's source of truth for Pro status and the free-import quota. The real
/// `EntitlementManager` conforms to this; it is `@MainActor` because the UI
/// reads it directly and `refresh()` mutates published state.
@MainActor
public protocol EntitlementProviding: AnyObject {
    var isPro: Bool { get }
    /// The free-tier import cap (from the entitlement API — never hardcoded in UI).
    var freeImportLimit: Int { get }
    /// How many free imports remain this period.
    var freeImportsRemaining: Int { get }
    /// Re-pull entitlement state (e.g. right after a successful purchase).
    func refresh() async
}

/// Loads the current offering and performs purchase / restore. The real
/// implementation wraps RevenueCat's `Purchases`; the UI only ever sees the
/// `Paywall*` value types.
@MainActor
public protocol PaywallPurchasing: AnyObject {
    /// Fetch the current offering (annual + monthly), with real localized prices
    /// and this user's trial eligibility. Throws `PaywallError.loadFailed`.
    func loadOffering() async throws -> PaywallOffering
    /// Purchase the given plan. Returns `.cancelled` for a user cancel (no error);
    /// throws `PaywallError.purchaseFailed` for real failures.
    func purchase(_ plan: PaywallPlan) async throws -> PurchaseOutcome
    /// Restore prior purchases. Throws `PaywallError.restoreFailed` on failure.
    func restore() async throws -> RestoreOutcome
}
