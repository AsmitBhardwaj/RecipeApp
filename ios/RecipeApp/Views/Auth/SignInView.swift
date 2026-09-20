//
//  SignInView.swift
//  RecipeApp
//
//  The mandatory account gate (Stage 3): Sign in with Apple, Google, and
//  email/password. Shown after onboarding to a returning user who is signed out.
//  First-run sign-in now happens on onboarding screen 4 (see OnboardingView);
//  both hosts drive the identical flows via the shared `AuthMethodsView`. Apple
//  is native (no dependency); Google runs the OAuth flow in
//  GoogleSignInController; email/password posts to the backend directly.
//

import RecipeKit
import SwiftUI

struct SignInView: View {
    @ObservedObject var auth: AuthModel

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header

                // Email always visible here (the classic gate look); the shared
                // component owns the Apple/Google/email flows.
                AuthMethodsView(auth: auth, emailStyle: .inline)

                Text("By continuing you agree to our Terms and Privacy Policy.")
                    .font(.caption2)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            .padding(24)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(Color.textPrimary)
        .appBackground()
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text("Welcome")
                .font(.editorialTitle(size: 34))
            Text("Create an account or sign in to save your recipes and sync them across your devices.")
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 24)
        .padding(.bottom, 4)
    }
}

/// Keeps the (non-ObservableObject) Google controller alive for a view's
/// lifetime without recreating it each render. Shared by `AuthMethodsView`.
@MainActor
final class GoogleSignInControllerBox: ObservableObject {
    let controller = GoogleSignInController()
}
