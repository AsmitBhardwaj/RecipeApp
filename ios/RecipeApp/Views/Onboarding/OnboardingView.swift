//
//  OnboardingView.swift
//  RecipeApp
//
//  The first-run flow: a 4-screen intro that ends in sign-in. Replaces the old
//  6-page swipe intro entirely.
//
//    1. Promise      — rounded dish photo card, "Get started"
//    2. Share import — vector share-sheet illustration, "Continue"
//    3. Kitchen      — pantry + "you could make" panel, "Continue"
//    4. Sign in      — app mark + the shared AuthMethodsView (no skip)
//
//  Each screen is built from `OnboardingScaffold`: a 44pt header (brand lockup +
//  Skip on 1–3, empty on 4) and a pinned bottom block of page dots + button.
//  "Skip" on screens 1–3 jumps straight to sign-in; there is no skip on screen
//  4. Completion is driven by auth: reaching a signed-in state ends onboarding
//  (RootView then shows the app), and we record `hasCompletedOnboarding` so a
//  later sign-out lands on the plain sign-in gate rather than replaying this
//  flow.
//
//  No notification permission is requested here (it is requested on the first
//  Cook Mode timer start — see CookTimerNotificationScheduler).
//

import SwiftUI

struct OnboardingView: View {
    @ObservedObject var auth: AuthModel
    /// Called once the user is signed in (records onboarding completion).
    let onComplete: () -> Void

    @State private var page = 0
    private let pageCount = 4

    var body: some View {
        TabView(selection: $page) {
            OnboardingPromiseScreen(page: page, total: pageCount, onSkip: skip, onContinue: advance).tag(0)
            OnboardingShareScreen(page: page, total: pageCount, onSkip: skip, onContinue: advance).tag(1)
            OnboardingKitchenScreen(page: page, total: pageCount, onSkip: skip, onContinue: advance).tag(2)
            OnboardingSignInScreen(auth: auth, page: page, total: pageCount).tag(3)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // Single full-screen background (cream + paper grain) behind the
        // transparent pages, so the grain is uniform and extends under the home
        // indicator instead of leaving a flat strip.
        .appBackground()
        .foregroundStyle(Color.textPrimary)
        .onChange(of: auth.isSignedIn) { _, signedIn in
            if signedIn { onComplete() }
        }
        // If already signed in when this appears (edge case), finish immediately.
        .onAppear { if auth.isSignedIn { onComplete() } }
    }

    private func advance() {
        withAnimation { page = min(page + 1, pageCount - 1) }
    }

    private func skip() {
        withAnimation { page = pageCount - 1 }
    }
}

#Preview {
    OnboardingView(auth: AuthModel(), onComplete: {})
}
