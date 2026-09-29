import SwiftUI

/// The first screen after launch (before sign-in). Stores nothing about the user;
/// Continue goes to sign-in, Skip goes to sign-in too but leaves the plan answers
/// unset (Plan on a Budget runs its setup flow the first time it's opened).
struct ValueView: View {
    let onContinue: () -> Void
    let onSkip: () -> Void

    var body: some View {
        OnboardingValueScreen()
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                OnboardingPrimaryButton(title: "Continue", action: onContinue)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .padding(.bottom, 10)
                    .background(Color.creamTint)
            }
            .foregroundStyle(Color.textPrimary)
            .background(Color.creamTint.ignoresSafeArea())
    }

    private var header: some View {
        HStack {
            PlatterMark(size: 36)
                .accessibilityLabel("Platter")
            Spacer()
            Button("Skip", action: onSkip)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.textSecondary)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityHint("Skips the questions; you can set them up later in Meal Plan")
        }
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background(Color.creamTint)
    }
}
