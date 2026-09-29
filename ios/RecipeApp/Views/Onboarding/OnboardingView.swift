import RecipeKit
import SwiftUI

/// Signed-in first-run quiz. The order is launch → Value → Sign in → quiz; the
/// Value screen is hosted by `RootView` before sign-in, so this view is only the
/// quiz (People onward) and finishing it (save answers → main app, which opens
/// Plan on a Budget and generates the first week).
struct OnboardingView: View {
    @ObservedObject var auth: AuthModel
    @EnvironmentObject private var preferences: CookingPreferencesModel
    @EnvironmentObject private var subscriptions: SubscriptionService

    @StateObject private var sync: SyncCoordinator
    @State private var quiz: PlanQuizModel?

    init(auth: AuthModel) {
        self.auth = auth
        let userID = auth.currentUser?.id ?? "unknown"
        _sync = StateObject(wrappedValue: SyncCoordinator(userId: userID, tokenProvider: { try await auth.validAccessToken() }))
    }

    var body: some View {
        ZStack {
            if let quiz {
                // First step has no Back: there's no screen before it now.
                PlanQuizFlow(model: quiz, onExit: nil, onFinish: finish)
            }
        }
        .foregroundStyle(Color.textPrimary)
        .background(Color.creamTint.ignoresSafeArea())
        .onAppear {
            // Reinstall / new device: pull the synced answers. If the account already
            // finished onboarding elsewhere, the model flips and the main app opens.
            preferences.attachSync(sync)
            sync.triggerSync()
            if quiz == nil {
                quiz = PlanQuizModel(session: .onboarding(from: preferences.preferences, deviceCountry: GroceryCountry.guessFromLocale()))
            }
        }
    }

    /// "Build my week": save every answer, then let the main app generate the week.
    private func finish(_ answers: CookingPreferences) {
        preferences.save(answers)
        preferences.requestPlanBuild()
        sync.triggerSync()
        // No paywall here: the free week comes first, and the Platter Pro teaser
        // follows its reveal. Still mark the session so the periodic app-open
        // paywall doesn't land on top of that first plan.
        subscriptions.markOnboardingPaywallShown()
        preferences.completeOnboarding()
    }
}

#Preview {
    OnboardingView(auth: AuthModel())
        .environmentObject(CookingPreferencesModel(userScope: "preview"))
        .environmentObject(SubscriptionService())
}
