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

    @AppStorage("hasCompletedOnboarding") private var legacyOnboardingCompletion = false
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
        if !auth.isSignedIn {
            SignInView(auth: auth)
        } else if let userID = auth.currentUser?.id {
            SignedInRoot(
                recipeProvider: recipeProvider,
                auth: auth,
                userID: userID,
                legacyCompletion: legacyOnboardingCompletion
            )
        }
    }
}

private struct SignedInRoot: View {
    let recipeProvider: RecipeProvider
    @ObservedObject var auth: AuthModel
    @StateObject private var cookingPreferences: CookingPreferencesModel

    init(recipeProvider: RecipeProvider, auth: AuthModel, userID: String, legacyCompletion: Bool) {
        self.recipeProvider = recipeProvider
        self.auth = auth
        _cookingPreferences = StateObject(wrappedValue: CookingPreferencesModel(
            userScope: userID,
            legacyCompletion: legacyCompletion
        ))
    }

    var body: some View {
        Group {
            if cookingPreferences.hasCompletedOnboarding {
                MainTabView(recipeProvider: recipeProvider, auth: auth)
            } else {
                OnboardingView(auth: auth)
            }
        }
        .environmentObject(auth)
        .environmentObject(cookingPreferences)
    }
}

#Preview("Onboarding") {
    RootView(recipeProvider: MockRecipeProvider(), auth: AuthModel())
}
