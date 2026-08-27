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
        if !hasCompletedOnboarding {
            // Value first: show the illustrated onboarding before any auth wall.
            OnboardingView { hasCompletedOnboarding = true }
        } else if auth.isSignedIn {
            MainTabView(recipeProvider: recipeProvider)
                .environmentObject(auth)
        } else {
            // Mandatory account gate, after onboarding.
            SignInView(auth: auth)
        }
    }
}

#Preview("Onboarding") {
    RootView(recipeProvider: MockRecipeProvider(), auth: AuthModel())
}
