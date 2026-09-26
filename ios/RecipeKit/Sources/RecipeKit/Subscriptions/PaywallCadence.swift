//
//  PaywallCadence.swift
//  RecipeKit
//
//  Pure rules for WHEN the Platter Pro paywall is presented on its own (the
//  onboarding step and the periodic app-open prompt), kept free of SwiftUI so the
//  frequency cap and skip conditions are unit-testable. The feature triggers
//  (import limit, nutrition, kitchen, budget) are presented directly by their
//  screens and are not governed here.
//

import Foundation

/// Why the paywall is being presented. `onboarding` and `appOpen` are the
/// presentation-rule triggers; the rest are the existing feature gates.
public enum PaywallTrigger: String, Sendable, Equatable {
    case onboarding
    case appOpen
    case importLimit
    case nutrition
    case kitchen
    case budget
}

public enum PaywallCadence {
    /// At most one app-open paywall per account per this interval (3 days).
    public static let appOpenMinInterval: TimeInterval = 3 * 24 * 60 * 60

    /// Whether to present the app-open paywall now, for a signed-in FREE user.
    ///
    /// Only decides once the server entitlement for the current account has
    /// resolved, so Pro users never see a flash. Returns false (don't show) when
    /// offline / unresolved, for Pro users, in the same session as the onboarding
    /// paywall, on a share/import launch, while an import or purchase is in
    /// progress, on top of another sheet, or within the frequency cap.
    public static func shouldPresentOnAppOpen(
        serverEntitlementResolved: Bool,
        isPro: Bool,
        lastShown: Date?,
        now: Date,
        onboardingPaywallShownThisSession: Bool,
        launchedFromShareOrImport: Bool,
        importInProgress: Bool,
        purchaseInProgress: Bool,
        anotherSheetPresented: Bool,
        minInterval: TimeInterval = appOpenMinInterval
    ) -> Bool {
        guard serverEntitlementResolved else { return false }
        guard !isPro else { return false }
        guard !onboardingPaywallShownThisSession else { return false }
        guard !launchedFromShareOrImport else { return false }
        guard !importInProgress else { return false }
        guard !purchaseInProgress else { return false }
        guard !anotherSheetPresented else { return false }
        if let lastShown, now.timeIntervalSince(lastShown) < minInterval {
            return false
        }
        return true
    }
}

/// Per-account record of when the app-open paywall was last shown, stored in the
/// App Group so it is stable across launches. Injectable `UserDefaults` for tests.
public struct PaywallPresentationStore {
    private static let prefix = "paywall.appOpen.lastShown."
    private let defaults: UserDefaults?

    public init(defaults: UserDefaults? = UserDefaults(suiteName: AppGroup.identifier)) {
        self.defaults = defaults
    }

    public func lastShown(accountId: String?) -> Date? {
        guard let accountId, !accountId.isEmpty, let defaults else { return nil }
        let key = Self.prefix + accountId
        guard defaults.object(forKey: key) != nil else { return nil }
        let seconds = defaults.double(forKey: key)
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }

    public func recordShown(accountId: String?, at date: Date = Date()) {
        guard let accountId, !accountId.isEmpty, let defaults else { return }
        defaults.set(date.timeIntervalSince1970, forKey: Self.prefix + accountId)
    }
}
