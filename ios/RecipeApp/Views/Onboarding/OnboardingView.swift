//
//  OnboardingView.swift
//  RecipeApp
//
//  The first-run flow: a 4-screen intro that ends in sign-in. Replaces the old
//  6-page swipe intro entirely.
//
//    1. Promise      — full-bleed dish photo, torn bottom edge, "Get started"
//    2. Share import — vector share-sheet illustration, "Continue"
//    3. Kitchen      — pantry chips + "you could make" cards, "Continue"
//    4. Sign in      — app mark + the shared AuthMethodsView (no skip)
//
//  A 4-segment progress bar sits at the top of every screen. "Skip" on screens
//  1–3 jumps straight to sign-in; there is no skip on screen 4. Completion is
//  driven by auth: reaching a signed-in state ends onboarding (RootView then
//  shows the app), and we record `hasCompletedOnboarding` so a later sign-out
//  lands on the plain sign-in gate rather than replaying this flow.
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
        ZStack(alignment: .top) {
            TabView(selection: $page) {
                OnboardingPromiseScreen(onContinue: advance).tag(0)
                OnboardingShareScreen(onContinue: advance).tag(1)
                OnboardingKitchenScreen(onContinue: advance).tag(2)
                OnboardingSignInScreen(auth: auth).tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea(.container, edges: .top)   // screen 1 photo runs edge-to-edge

            topBar
        }
        .foregroundStyle(Color.textPrimary)
        .onChange(of: auth.isSignedIn) { _, signedIn in
            if signedIn { onComplete() }
        }
        // If already signed in when this appears (edge case), finish immediately.
        .onAppear { if auth.isSignedIn { onComplete() } }
    }

    // Progress bar + Skip, floating in the top safe area over whatever screen.
    private var topBar: some View {
        HStack(spacing: 12) {
            OnboardingProgressBar(current: page, total: pageCount)
            if page < pageCount - 1 {
                Button("Skip") { withAnimation { page = pageCount - 1 } }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.textPrimary)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 44)              // 44pt touch target
                    .background(.ultraThinMaterial, in: Capsule())
                    .accessibilityHint("Skips to sign in")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private func advance() {
        withAnimation { page = min(page + 1, pageCount - 1) }
    }
}

/// A 4-segment progress bar; segments up to and including `current` are filled.
struct OnboardingProgressBar: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<total, id: \.self) { i in
                Capsule()
                    .fill(i <= current ? Color.accentColor : Color.textSecondary.opacity(0.3))
                    .frame(height: 5)
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.5), lineWidth: 0.5))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(.ultraThinMaterial, in: Capsule())   // legible over photo or cream
        .animation(.easeInOut(duration: 0.25), value: current)
        .accessibilityElement()
        .accessibilityLabel("Step \(current + 1) of \(total)")
    }
}

#Preview {
    OnboardingView(auth: AuthModel(), onComplete: {})
}
