import RecipeKit
import SwiftUI

/// First-run onboarding (sign-in stays first, in `RootView`):
///   Value screen → People → Diet → Food mood → Appliances → Store → Budget
/// The quiz screens live in `PlanQuizFlow`; this view owns the Value screen, the
/// hand-off to the quiz, and finishing (save answers → paywall → main app, which
/// opens Plan on a Budget and generates the first week).
struct OnboardingView: View {
    @ObservedObject var auth: AuthModel
    @EnvironmentObject private var preferences: CookingPreferencesModel
    @EnvironmentObject private var subscriptions: SubscriptionService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @StateObject private var sync: SyncCoordinator

    /// Created on the first Continue (needs the preferences environment object) and
    /// kept, so Back to the Value screen and forward again keeps the answers.
    @State private var quiz: PlanQuizModel?
    @State private var showingQuiz = false
    @State private var showingPaywall = false

    init(auth: AuthModel, startInQuiz: Bool = false) {
        self.auth = auth
        let userID = auth.currentUser?.id ?? "unknown"
        _sync = StateObject(wrappedValue: SyncCoordinator(userId: userID, tokenProvider: { try await auth.validAccessToken() }))
        _showingQuiz = State(initialValue: startInQuiz)
    }

    var body: some View {
        ZStack {
            if showingQuiz, let quiz {
                PlanQuizFlow(model: quiz, onExit: leaveQuiz, onFinish: finish)
            } else {
                valueScreen
            }
        }
        .foregroundStyle(Color.textPrimary)
        .background(Color.creamTint.ignoresSafeArea())
        .onAppear {
            // Reinstall / new device: pull the synced answers. If the account already
            // finished onboarding elsewhere, the model flips and the main app opens.
            preferences.attachSync(sync)
            sync.triggerSync()
            if showingQuiz && quiz == nil { quiz = makeQuiz() }
        }
        .sheet(isPresented: $showingPaywall, onDismiss: completeOnboarding) {
            PlatterProPaywallView()
                .environmentObject(subscriptions)
        }
    }

    // MARK: Value screen

    private var valueScreen: some View {
        OnboardingValueScreen()
            .safeAreaInset(edge: .top, spacing: 0) { valueHeader }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                OnboardingPrimaryButton(title: "Continue", action: startQuiz)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .padding(.bottom, 10)
                    .background(Color.creamTint)
            }
    }

    private var valueHeader: some View {
        HStack {
            PlatterMark(size: 36)
                .accessibilityLabel("Platter")
            Spacer()
            // Skipping leaves the plan answers unset; Plan on a Budget then runs the
            // Mood → Appliances → Store → Budget setup the first time it's opened.
            Button("Skip", action: skip)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.textSecondary)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityHint("Finishes onboarding without answering the questions")
        }
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background(Color.creamTint)
    }

    // MARK: Actions

    private func makeQuiz() -> PlanQuizModel {
        PlanQuizModel(session: .onboarding(from: preferences.preferences, deviceCountry: GroceryCountry.guessFromLocale()))
    }

    private func startQuiz() {
        if quiz == nil { quiz = makeQuiz() }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) { showingQuiz = true }
    }

    private func leaveQuiz() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) { showingQuiz = false }
    }

    /// "Build my week": save every answer, then let the main app generate the week.
    private func finish(_ answers: CookingPreferences) {
        preferences.save(answers)
        preferences.requestPlanBuild()
        finishOnboarding()
    }

    private func skip() {
        finishOnboarding()
    }

    private func finishOnboarding() {
        sync.triggerSync()

        // Keep onboarding mounted while the paywall is presented. Marking it
        // complete first would make SignedInRoot replace this view immediately,
        // preventing the sheet from appearing.
        if subscriptions.isProUnlocked {
            completeOnboarding()
        } else {
            // Final onboarding step: present the paywall once (trigger .onboarding),
            // dismissible immediately. Mark it so the periodic app-open paywall is
            // not also shown in this same session.
            subscriptions.markOnboardingPaywallShown()
            showingPaywall = true
        }
    }

    private func completeOnboarding() {
        preferences.completeOnboarding()
    }
}

#Preview {
    OnboardingView(auth: AuthModel())
        .environmentObject(CookingPreferencesModel(userScope: "preview"))
        .environmentObject(SubscriptionService())
}
