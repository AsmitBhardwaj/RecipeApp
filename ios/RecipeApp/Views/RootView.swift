//
//  RootView.swift
//  RecipeApp
//
//  Decides between the onboarding flow (first launch) and the main app.
//  Onboarding completion is persisted in `@AppStorage` so it only shows once.
//

import SwiftUI
import RecipeKit

struct RootView: View {
    let recipeProvider: RecipeProvider
    @ObservedObject var auth: AuthModel

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    /// In-app appearance override (App Group–backed). Applied here so it covers
    /// onboarding, the main app, and any sheets they present. Reading it here and
    /// writing it in Settings via the same key/store makes toggles apply live.
    @AppStorage(AppAppearance.storageKey, store: .appGroup) private var appearance: AppAppearance = .system

    var body: some View {
        content
            .preferredColorScheme(preferredScheme)
    }

    /// Normally the user's appearance override. In the DEBUG paywall screenshot
    /// harness the paywall is rendered INLINE as root (not as a sheet), so force
    /// dark here to match how it actually looks when presented as a sheet.
    private var preferredScheme: ColorScheme? {
        #if DEBUG
        if ProcessInfo.processInfo.environment["PAYWALL_PREVIEW"] != nil { return .dark }
        #endif
        return appearance.colorScheme
    }

    @ViewBuilder
    private var content: some View {
        #if DEBUG
        if let variant = ProcessInfo.processInfo.environment["PAYWALL_PREVIEW"] {
            debugPaywall(variant)
        } else {
            gate
        }
        #else
        gate
        #endif
    }

    // Onboarding + auth gate (from main's 4-screen flow). Auth wins first: a
    // signed-in user (this device or a prior session) goes straight to the app;
    // otherwise a first run shows the 4-screen onboarding (which ends in
    // sign-in), and an onboarded-but-signed-out user gets the plain account gate.
    @ViewBuilder
    private var gate: some View {
        if auth.isSignedIn {
            MainTabView(recipeProvider: recipeProvider, auth: auth)
                .environmentObject(auth)
        } else if !hasCompletedOnboarding {
            OnboardingView(auth: auth, onComplete: { hasCompletedOnboarding = true })
        } else {
            SignInView(auth: auth)
        }
    }

    #if DEBUG
    /// Screenshot harness: render a specific PaywallView variant at launch via
    /// the `PAYWALL_PREVIEW` env var. Never reachable in release.
    @ViewBuilder
    private func debugPaywall(_ variant: String) -> some View {
        let entitlements = MockEntitlementProvider(freeImportLimit: 10)
        switch variant {
        case "pantry":
            PaywallView(trigger: .pantry, entitlements: entitlements,
                        purchasing: MockPaywallPurchasing(scenario: .trialEligible))
        case "monthly":
            PaywallView(trigger: .importLimit, entitlements: entitlements,
                        purchasing: MockPaywallPurchasing(scenario: .trialEligible), initialPeriod: .monthly)
        case "notEligible":
            PaywallView(trigger: .importLimit, entitlements: entitlements,
                        purchasing: MockPaywallPurchasing(scenario: .notTrialEligible))
        case "ax5":
            PaywallView(trigger: .importLimit, entitlements: entitlements,
                        purchasing: MockPaywallPurchasing(scenario: .trialEligible))
                .environment(\.dynamicTypeSize, .accessibility5)
        default:   // "importLimit"
            PaywallView(trigger: .importLimit, entitlements: entitlements,
                        purchasing: MockPaywallPurchasing(scenario: .trialEligible))
        }
    }
    #endif
}

#Preview("Onboarding") {
    RootView(recipeProvider: MockRecipeProvider(), auth: AuthModel())
}
