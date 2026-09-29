//
//  PaywallTeaserView.swift
//  RecipeApp
//
//  "Keep a fresh week coming" — the full-screen teaser that fronts the paywall
//  wherever a free account reaches the Pro line (after the free week's reveal, a
//  second plan, out of swaps, "New plan"). One button; no close, no prices. "View
//  our plans" presents the existing paywall on top; closing it (or buying Pro)
//  reports back through `onClose`, which dismisses both.
//

import SwiftUI
import RecipeKit

struct PaywallTeaserView: View {
    /// Called when the paywall is dismissed (close or purchase); the flag is
    /// whether Pro is now unlocked.
    let onClose: (_ isPro: Bool) -> Void

    @EnvironmentObject private var subscriptions: SubscriptionService
    @State private var showingPaywall = false

    private static let benefits: [(title: String, subtitle: String)] = [
        ("A new budget plan every week", "Fresh dinners, same budget, every Sunday"),
        ("Unlimited dinner swaps", "Don't like a meal? Swap it in a tap"),
        ("Unlimited recipe imports", "Save from Instagram, TikTok and blogs"),
        ("Calories and macros", "On every recipe you save"),
        ("Cook from your pantry", "Ideas from what you already have"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                SoftAssetImage(name: "sticker_hero", size: 180, cornerRadius: 32)
                    .padding(.top, 24)
                Text("Keep a fresh week coming")
                    .font(.editorialTitle(size: 34, relativeTo: .largeTitle))
                    .foregroundStyle(Color.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 20)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilitySortPriority(2)
                Text("This week is on us. Platter Pro plans every week after it, on your budget.")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                    .accessibilitySortPriority(1)
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Self.benefits, id: \.title) { benefit in
                        benefitRow(benefit.title, benefit.subtitle)
                    }
                }
                .padding(.top, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .background(Color.appBackground.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .interactiveDismissDisabled()
        .sheet(isPresented: $showingPaywall, onDismiss: { onClose(subscriptions.isProUnlocked) }) {
            PlatterProPaywallView().environmentObject(subscriptions)
        }
    }

    private func benefitRow(_ title: String, _ subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.accentColor, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.textPrimary)
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(subtitle)")
    }

    private var bottomBar: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showingPaywall = true
        } label: {
            Text("View our plans")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("View our plans")
        .accessibilityHint("Shows Platter Pro subscription options")
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(Color.appBackground)
    }
}

#Preview {
    PaywallTeaserView { _ in }
        .environmentObject(SubscriptionService())
}
