//
//  RootView.swift
//  RecipeApp
//
//  Decides between the first-run flow and the main app:
//  launch → Value → Sign in → quiz → main. The Value screen is device-level (no
//  account exists yet); once seen it never returns, including after sign-out.
//

import SwiftUI
import RecipeKit

struct RootView: View {
    let recipeProvider: RecipeProvider
    @ObservedObject var auth: AuthModel
    let subscriptions: SubscriptionService

    @AppStorage("hasCompletedOnboarding") private var legacyOnboardingCompletion = false
    /// In-app appearance override (App Group–backed). Applied here so it covers
    /// onboarding, the main app, and any sheets they present. Reading it here and
    /// writing it in Settings via the same key/store makes toggles apply live.
    @AppStorage(AppAppearance.storageKey, store: .appGroup) private var appearance: AppAppearance = .system

    /// Cold-launch splash. `@State` on the root means it's `true` once per process
    /// launch and survives background/foreground (the view tree stays alive), so
    /// the splash never replays on resume.
    @State private var showSplash = true

    private let flowStore = OnboardingFlowStore()
    @State private var hasSeenValue = OnboardingFlowStore().hasSeenValue

    var body: some View {
        ZStack {
            content
            if showSplash {
                SplashView()
                    .transition(.opacity)
                    .zIndex(1)
                    .onAppear(perform: scheduleSplashDismiss)
            }
        }
        .preferredColorScheme(appearance.colorScheme)
    }

    /// Hold the static splash for a fixed 2 seconds on cold launch, then crossfade
    /// to the main content. Scheduled from the splash's `onAppear`, which fires
    /// once (the splash is removed permanently afterwards, not re-shown on resume).
    private func scheduleSplashDismiss() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.easeInOut(duration: 0.4)) { showSplash = false }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !auth.isSignedIn {
            switch OnboardingRouter.route(isSignedIn: false, hasSeenValue: hasSeenValue,
                                          hasCompletedOnboarding: false, skippedQuiz: false) {
            case .value:
                ValueView(onContinue: { finishValue(skipped: false) }, onSkip: { finishValue(skipped: true) })
                    .transition(.opacity)
            default:
                SignInView(auth: auth)
                    .transition(.opacity)
            }
        } else if let userID = auth.currentUser?.id {
            SignedInRoot(
                recipeProvider: recipeProvider,
                auth: auth,
                subscriptions: subscriptions,
                userID: userID,
                legacyCompletion: legacyOnboardingCompletion
            )
            // A signed-in user (incl. one upgrading from a build without the flag)
            // never sees Value again, even after signing out.
            .onAppear { flowStore.markValueSeen() }
        }
    }

    private func finishValue(skipped: Bool) {
        flowStore.markValueSeen(skipped: skipped)
        withAnimation(.easeInOut(duration: 0.25)) { hasSeenValue = true }
    }
}

private struct SignedInRoot: View {
    let recipeProvider: RecipeProvider
    @ObservedObject var auth: AuthModel
    let subscriptions: SubscriptionService
    @StateObject private var cookingPreferences: CookingPreferencesModel
    /// Value's Skip was tapped before this sign-in: no quiz; MainTabView finishes
    /// onboarding with the answers unset.
    @StateObject private var reminders: PlanReminderModel
    @State private var skippedQuiz = OnboardingFlowStore().skippedQuiz

    init(
        recipeProvider: RecipeProvider,
        auth: AuthModel,
        subscriptions: SubscriptionService,
        userID: String,
        legacyCompletion: Bool
    ) {
        self.recipeProvider = recipeProvider
        self.auth = auth
        self.subscriptions = subscriptions
        _reminders = StateObject(wrappedValue: PlanReminderModel(userId: userID, isPro: { [weak subscriptions] in subscriptions?.isProUnlocked ?? false }))
        _cookingPreferences = StateObject(wrappedValue: CookingPreferencesModel(
            userScope: userID,
            legacyCompletion: legacyCompletion
        ))
    }

    var body: some View {
        Group {
            switch OnboardingRouter.route(
                isSignedIn: true, hasSeenValue: true,
                hasCompletedOnboarding: cookingPreferences.hasCompletedOnboarding, skippedQuiz: skippedQuiz
            ) {
            case .quiz:
                OnboardingView(auth: auth)
            default:
                MainTabView(
                    recipeProvider: recipeProvider,
                    auth: auth,
                    subscriptions: subscriptions
                )
            }
        }
        .environmentObject(auth)
        .environmentObject(cookingPreferences)
        .environmentObject(reminders)
    }
}

#Preview("First run") {
    RootView(
        recipeProvider: MockRecipeProvider(),
        auth: AuthModel(),
        subscriptions: SubscriptionService()
    )
}
