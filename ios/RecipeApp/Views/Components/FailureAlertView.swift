//
//  FailureAlertView.swift
//  RecipeApp
//
//  Custom modal replacement for the native failure `.alert()`. Native iOS
//  alerts only tint button *text* — they can't render a filled/colored button
//  background (a hard platform limitation). This overlay reproduces the alert's
//  layout (title + emoji, message, single button) but with a fully filled sage
//  OK button (centralized `AccentColor` token, cream text on top).
//
//  It is presentation only — the trigger/tracking still lives in
//  `PendingJobsModel` (fires once per newly-failed job) and the differentiated
//  per-code copy still comes from `RecipeProviderError`. This view just renders
//  the strings it's handed and calls `onDismiss` on OK.
//
//  Dismiss matches the native alert it replaces: the OK button only. The scrim
//  blocks touches to the content behind but does not itself dismiss.
//

import SwiftUI

struct FailureAlertView: View {
    let title: String
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            // Dimming scrim. Blocks interaction with the app behind; does not
            // dismiss on tap (native alerts don't either).
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}   // swallow taps without dismissing

            VStack(spacing: 12) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.textPrimary)
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.callout)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: onDismiss) {
                    Text("OK")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .padding(24)
            .frame(maxWidth: 300)
            .background(Color.appBackground, in: RoundedRectangle(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(Color.cardEdge, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
            .padding(40)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
    }
}

#Preview {
    FailureAlertView(
        title: "Couldn't add recipe 😔",
        message: "We couldn't find a recipe on this page.",
        onDismiss: {}
    )
}
