//
//  PaywallCenter.swift
//  RecipeApp
//
//  App-wide coordinator that owns the paywall's dependencies and drives its
//  presentation. Views call `present(_:)` or gate a Pro-only action with
//  `requirePro(trigger:)`; the app shell presents `PaywallView` off `active`.
//
//  PLACEHOLDER WIRING: the entitlements + purchasing here are the RecipeKit
//  mocks. When `feature/pro-entitlements` lands, swap these two lines for the
//  real `EntitlementManager` (EntitlementProviding) and RevenueCat-backed
//  purchasing (PaywallPurchasing). Nothing else in the app changes — see
//  docs/PAYWALL_WIRING.md.
//

import Foundation
import RecipeKit

/// Identifiable wrapper so a `PaywallTrigger` can drive `.sheet(item:)`.
struct ActivePaywall: Identifiable {
    let trigger: PaywallTrigger
    var id: String {
        switch trigger { case .importLimit: "importLimit"; case .pantry: "pantry"; case .settings: "settings" }
    }
}

@MainActor
final class PaywallCenter: ObservableObject {
    @Published var active: ActivePaywall?

    let entitlements: any EntitlementProviding
    let purchasing: any PaywallPurchasing

    nonisolated init(
        entitlements: any EntitlementProviding = MockEntitlementProvider(),
        purchasing: any PaywallPurchasing = MockPaywallPurchasing()
    ) {
        self.entitlements = entitlements
        self.purchasing = purchasing
    }

    var isPro: Bool { entitlements.isPro }

    func present(_ trigger: PaywallTrigger) { active = ActivePaywall(trigger: trigger) }

    /// Gate a Pro-only action: returns true if the user is Pro; otherwise
    /// presents the paywall for `trigger` and returns false so the caller can
    /// skip the work (e.g. not hit a Pro-only endpoint).
    @discardableResult
    func requirePro(trigger: PaywallTrigger) -> Bool {
        if entitlements.isPro { return true }
        present(trigger)
        return false
    }
}
