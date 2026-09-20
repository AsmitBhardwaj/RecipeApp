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
            .preferredColorScheme(appearance.colorScheme)
    }

    @ViewBuilder
    private var content: some View {
        #if DEBUG
        if ProcessInfo.processInfo.environment["UI_SCREENSHOT_MAIN"] == "1" {
            // Screenshot harness only: render the signed-in app shell (empty
            // library) without a live account. Never reachable in release.
            MainTabView(recipeProvider: recipeProvider, auth: auth)
                .environmentObject(auth)
        } else {
            gate
        }
        #else
        gate
        #endif
    }

    @ViewBuilder
    private var gate: some View {
        if auth.isSignedIn {
            // Already signed in (this device or a prior session) → straight to the
            // app, skipping onboarding entirely.
            MainTabView(recipeProvider: recipeProvider, auth: auth)
                .environmentObject(auth)
        } else if !hasCompletedOnboarding {
            // First run: the 4-screen flow, which ends in sign-in (screen 4).
            OnboardingView(auth: auth, onComplete: { hasCompletedOnboarding = true })
        } else {
            // Onboarded before but signed out → the plain account gate, not a
            // replay of onboarding.
            SignInView(auth: auth)
        }
    }
}

#Preview("Onboarding") {
    RootView(recipeProvider: MockRecipeProvider(), auth: AuthModel())
}
