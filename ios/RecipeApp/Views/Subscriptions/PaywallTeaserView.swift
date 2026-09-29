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
//  Sage gradient background with cream type. Cream (#F7F3EA) on sage measures
//  4.96:1 at full opacity; the translucent subtitles use 92% / 85% (not the
//  80% / 75% first asked for) because those measured ~4.0:1 — under the 4.5:1
//  body-text bar.
//

import SwiftUI
import RecipeKit

struct PaywallTeaserView: View {
    /// The user's current plan, for the "Next week" preview card. Nil falls back to
    /// generic copy.
    var budget: Int? = nil
    var dinners: Int? = nil
    /// Called when the paywall is dismissed (close or purchase); the flag is
    /// whether Pro is now unlocked.
    let onClose: (_ isPro: Bool) -> Void

    @EnvironmentObject private var subscriptions: SubscriptionService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingPaywall = false
    @State private var pulse = false
    @State private var shine: CGFloat = -0.6

    private static let cream = Color(hex: "F7F3EA")
    private static let sage = Color(hex: "56704F")
    private static let deepSage = Color(hex: "3E5238")

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
                Text("PLATTER PRO")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(2)
                    .foregroundStyle(Self.cream)
                    .padding(.top, 8)
                    .accessibilityHidden(true)
                Text("Keep a fresh week coming")
                    .font(.editorialTitle(size: 34, relativeTo: .largeTitle))
                    .foregroundStyle(Self.cream)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilitySortPriority(3)
                Text("This week is on us. Platter Pro plans every week after it, on your budget.")
                    .font(.system(size: 16))
                    .foregroundStyle(Self.cream.opacity(0.92))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                    .accessibilitySortPriority(2)

                NextWeekPreview(budget: budget, dinners: dinners)
                    .padding(.top, 20)
                    .padding(.horizontal, 6)

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Self.benefits, id: \.title) { benefit in
                        benefitRow(benefit.title, benefit.subtitle)
                    }
                }
                .padding(.top, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilitySortPriority(1)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .background {
            LinearGradient(colors: [Self.sage, Self.deepSage], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .preferredColorScheme(.dark)   // light status bar over the sage
        .interactiveDismissDisabled()
        .sheet(isPresented: $showingPaywall, onDismiss: { onClose(subscriptions.isProUnlocked) }) {
            PlatterProPaywallView().environmentObject(subscriptions)
        }
        .task { await playButtonPulse() }
    }

    private func benefitRow(_ title: String, _ subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Self.cream)
                .frame(width: 24, height: 24)
                .overlay { Circle().strokeBorder(Self.cream, lineWidth: 1.5) }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Self.cream)
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(Self.cream.opacity(0.85))
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
                .foregroundStyle(Self.sage)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(Self.cream, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    // One soft shine sweep across the button.
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [.clear, Color.white.opacity(0.55), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: geo.size.width * 0.4)
                        .offset(x: shine * geo.size.width)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .allowsHitTesting(false)
                }
                .scaleEffect(pulse ? 1.03 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("View our plans")
        .accessibilityHint("Shows Platter Pro subscription options")
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    /// A gentle pulse + shine, once, shortly after the screen appears.
    private func playButtonPulse() async {
        guard !reduceMotion else { return }
        try? await Task.sleep(nanoseconds: 600_000_000)
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.9)) { shine = 1.2 }
        withAnimation(.easeInOut(duration: 0.45)) { pulse = true }
        try? await Task.sleep(nanoseconds: 450_000_000)
        withAnimation(.easeInOut(duration: 0.45)) { pulse = false }
    }
}

// MARK: - "Next week" preview

/// A locked, personalized peek at next week's plan: a white dinner-style card
/// (rotated -2°) with another peeking behind it (+3°, 60% opacity). The rows are
/// placeholders under a frosted blur with a centered lock badge.
private struct NextWeekPreview: View {
    let budget: Int?
    let dinners: Int?

    private static let categories: [FoodSticker] = [.pasta, .curry, .salad]

    private var summary: String {
        switch (budget, dinners) {
        case let (budget?, dinners?): return "$\(budget) · \(dinners) \(dinners == 1 ? "dinner" : "dinners")"
        case let (budget?, nil): return "$\(budget)"
        case let (nil, dinners?): return "\(dinners) \(dinners == 1 ? "dinner" : "dinners")"
        default: return "Fresh dinners"
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DinnerCardSurface.radius + 2, style: .continuous)
                .fill(Color.white)
                .opacity(0.6)
                .shadow(color: .black.opacity(0.06), radius: 12, x: 0, y: 4)
                .frame(height: 200)
                .rotationEffect(.degrees(3))
                .offset(x: 10, y: 6)

            VStack(spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Next week")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                    Spacer(minLength: 8)
                    Text(summary)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.textSecondary)
                }
                VStack(spacing: 8) {
                    ForEach(Array(Self.categories.enumerated()), id: \.offset) { _, category in
                        HStack(spacing: 12) {
                            DinnerTile(category: category, size: 40)
                            VStack(alignment: .leading, spacing: 7) {
                                Capsule().fill(Color(hex: "D9D6CF")).frame(height: 10)
                                Capsule().fill(Color(hex: "E8E6E1")).frame(width: 90, height: 8)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(10)
                .background(Color(hex: "F7F6F3"), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .blur(radius: 4)
                .overlay {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial).opacity(0.7)
                        Image(systemName: "lock.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Color(hex: "56704F"), in: Circle())
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(14)
            .dinnerCardSurface()
            .rotationEffect(.degrees(-2))
        }
        // The screen is forced dark for the light status bar; the card is a white
        // surface, so it keeps light-mode text and material.
        .environment(\.colorScheme, .light)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Next week's plan, locked. \(summary)")
    }
}

#Preview {
    PaywallTeaserView(budget: 85, dinners: 5) { _ in }
        .environmentObject(SubscriptionService())
}
