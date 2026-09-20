//
//  OnboardingScreens.swift
//  RecipeApp
//
//  The four onboarding screens and their shared copy/CTA styling. See
//  OnboardingView for the container (progress bar, skip, paging, completion).
//

import SwiftUI

// MARK: - Shared building blocks

/// Headline (DM Serif Display) + supporting body, centred. Scales with Dynamic
/// Type via the text styles.
private struct OnboardingCopy: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.editorialTitle(size: 30, relativeTo: .largeTitle))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.textPrimary)
            Text(message)
                .font(.callout)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)   // wrap, never clip
        }
        .padding(.horizontal, 32)
    }
}

private struct OnboardingCTA: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 50)     // >= 44pt touch target
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
    }
}

/// Top padding that clears the status bar + the floating progress bar for the
/// cream screens (2–4), which sit inside a top-safe-area-ignoring TabView.
private let onboardingTopInset: CGFloat = 76

// MARK: - 1. Promise

struct OnboardingPromiseScreen: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image("defaultRecipeImage4")
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: 380)
                .clipped()
                .clipShape(TornBottomEdge())
                .ignoresSafeArea(edges: .top)
                .accessibilityHidden(true)

            Spacer(minLength: 12)

            OnboardingCopy(
                title: "Save the recipe.\nCook it with what you've got.",
                message: "Platter pulls recipes out of Reels, TikToks and blogs, then helps you cook with what's already in your kitchen."
            )

            Spacer(minLength: 20)

            OnboardingCTA(title: "Get started", action: onContinue)
                .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .appBackground()
    }
}

/// A rectangle whose bottom edge is a torn/perforated sawtooth, so the cream
/// background shows through the tears beneath the photo.
struct TornBottomEdge: Shape {
    var tooth: CGFloat = 16
    var depth: CGFloat = 12

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: rect.maxX, y: 0))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - depth))
        var x = rect.maxX
        var down = true
        while x > 0 {
            x -= tooth
            let y = rect.maxY - (down ? 0 : depth)
            p.addLine(to: CGPoint(x: max(x, 0), y: y))
            down.toggle()
        }
        p.addLine(to: CGPoint(x: 0, y: 0))
        p.closeSubpath()
        return p
    }
}

// MARK: - 2. Share to import

struct OnboardingShareScreen: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: onboardingTopInset)

            ShareImportIllustration()
                .padding(.horizontal, 32)

            steps
                .padding(.top, 22)

            Spacer(minLength: 16)

            OnboardingCopy(
                title: "Share it to Platter.\nThat's the whole trick.",
                message: "From Instagram, TikTok or any recipe site, tap Share and pick Platter. We pull out the ingredients and steps for you."
            )

            Spacer(minLength: 20)

            OnboardingCTA(title: "Continue", action: onContinue)
                .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .appBackground()
    }

    private var steps: some View {
        HStack(spacing: 22) {
            numberedStep(1, "Tap Share")
            numberedStep(2, "Pick Platter")
        }
    }

    private func numberedStep(_ n: Int, _ label: String) -> some View {
        HStack(spacing: 8) {
            Text("\(n)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Color.accentColor, in: Circle())
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 3. Kitchen

struct OnboardingKitchenScreen: View {
    let onContinue: () -> Void

    private let pantry = ["Eggs", "Spinach", "Feta", "Rice", "Lemon", "Chickpeas"]

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: onboardingTopInset)

            pantryChips
                .padding(.horizontal, 24)

            VStack(spacing: 12) {
                suggestionCard(title: "Lemon Chickpea Bowl", uses: 4, asset: "defaultRecipeImage1")
                suggestionCard(title: "Spinach & Feta Rice", uses: 3, asset: "catSalad1")
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)

            Spacer(minLength: 16)

            OnboardingCopy(
                title: "Cook it with what you've got.",
                message: "Add what's in your fridge and pantry. Platter finds recipes you can make with it, so less food goes to waste."
            )

            Spacer(minLength: 20)

            OnboardingCTA(title: "Continue", action: onContinue)
                .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .appBackground()
    }

    // Two fixed rows of chips (a clean, intentional layout for the sample set).
    private var pantryChips: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) { ForEach(pantry.prefix(3), id: \.self) { chip($0) } }
            HStack(spacing: 10) { ForEach(pantry.suffix(3), id: \.self) { chip($0) } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Your pantry: " + pantry.joined(separator: ", "))
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1))
    }

    private func suggestionCard(title: String, uses: Int, asset: String) -> some View {
        HStack(spacing: 14) {
            Image(asset)
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.appRowTitle)
                    .foregroundStyle(Color.textPrimary)
                Text("Uses \(uses) of your items")
                    .font(.caption)
                    .foregroundStyle(Color.secondaryAccent)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(Color.appBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.cardEdge, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), uses \(uses) of your items")
    }
}

// MARK: - 4. Sign in

struct OnboardingSignInScreen: View {
    @ObservedObject var auth: AuthModel

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Spacer(minLength: onboardingTopInset - 20)

                PlatterMark(size: 72)
                    .accessibilityHidden(true)

                OnboardingCopy(
                    title: "One account, every device.",
                    message: "Sign in so your recipes, meal plan and grocery list follow you everywhere."
                )

                AuthMethodsView(auth: auth, emailStyle: .disclosure)
                    .padding(.horizontal, 24)
                    .padding(.top, 4)

                footer
                    .padding(.top, 4)
                    .padding(.bottom, 24)
            }
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .appBackground()
    }

    private var footer: some View {
        // TODO(platter): confirm live URLs. A Privacy page is expected at
        // https://platterapp.tech/privacy; there is NO Terms page yet — this
        // links to /terms as a placeholder and must be pointed at the real page
        // (or the link removed) before store submission.
        HStack(spacing: 4) {
            Link("Terms", destination: URL(string: "https://platterapp.tech/terms")!)
            Text("and").foregroundStyle(Color.textSecondary)
            Link("Privacy Policy", destination: URL(string: "https://platterapp.tech/privacy")!)
        }
        .font(.caption2)
        .tint(Color.secondaryAccent)
    }
}
