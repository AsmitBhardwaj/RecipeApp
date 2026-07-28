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

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        if hasCompletedOnboarding {
            MainTabView(recipeProvider: recipeProvider)
        } else {
            OnboardingView { hasCompletedOnboarding = true }
        }
    }
}

#Preview("Onboarding") {
    RootView(recipeProvider: MockRecipeProvider())
}
