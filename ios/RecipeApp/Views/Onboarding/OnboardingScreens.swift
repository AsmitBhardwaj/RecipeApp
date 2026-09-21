//
//  OnboardingScreens.swift
//  RecipeApp
//
//  The four onboarding screens and the shared chrome they sit in. See
//  OnboardingView for the paging container and auth-driven completion.
//
//  Every screen uses `OnboardingScaffold`: a 44pt header row (brand lockup +
//  Skip on 1–3, empty on 4), a vertically-centred content group, and a pinned
//  bottom block (page dots + a primary button, or the sign-in stack on screen
//  4). All colours come from the app's adaptive tokens so the flow follows
//  light/dark like every other screen.
//
//  Dynamic Type: only headlines, body copy and buttons scale. The header lockup
//  and the decorative sample illustrations (screen 2 mock post + share sheet,
//  screen 3 pantry panel) are capped at `.large` so they stay fixed. At
//  accessibility sizes the decorative art (screen 1 photo, screen 2
//  illustration, screen 3 panel) is hidden so the text gets the room; the middle
//  group scrolls only if it still doesn't fit, with the dots and button pinned.
//

import SwiftUI

// MARK: - Shared chrome

/// Header, centred content, pinned bottom block. `content` receives the full
/// screen height so a screen can size its illustration relative to the device.
/// The content is wrapped in a ScrollView sized to the available height so it
/// centres when it fits and scrolls only when it doesn't, without ever pushing
/// the dots and button off-screen.
struct OnboardingScaffold<Content: View, Bottom: View>: View {
    let page: Int
    let total: Int
    let showsLockup: Bool
    let onSkip: (() -> Void)?
    @ViewBuilder var content: (_ screenHeight: CGFloat) -> Content
    @ViewBuilder var bottom: () -> Bottom

    var body: some View {
        GeometryReader { screen in
            VStack(spacing: 0) {
                OnboardingHeader(showsLockup: showsLockup, onSkip: onSkip)
                    .frame(height: 44)
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                    // The lockup + Skip are chrome, not content — keep them fixed.
                    .dynamicTypeSize(...DynamicTypeSize.large)

                GeometryReader { geo in
                    ScrollView(.vertical, showsIndicators: false) {
                        content(screen.size.height)
                            .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .center)
                    }
                }

                VStack(spacing: 0) {
                    OnboardingPageDots(current: page, total: total)
                        .padding(.bottom, 20)
                    bottom()
                }
                .padding(.horizontal, 24)
                .padding(.top, 14)      // keep the dots clear of scrolled content on small screens
                .padding(.bottom, 34)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The brand lockup stays centred on screen while Skip is overlaid on the
/// trailing edge (screens 1–3). Screen 4 passes `showsLockup: false` / `onSkip:
/// nil`, leaving the 44pt row empty so vertical rhythm matches.
private struct OnboardingHeader: View {
    let showsLockup: Bool
    let onSkip: (() -> Void)?

    var body: some View {
        ZStack {
            if showsLockup {
                HStack(spacing: 10) {
                    PlatterMark(size: 30)
                    Text("Platter")
                        .font(.editorialTitle(size: 22))
                        .foregroundStyle(Color.textPrimary)
                }
                .accessibilityElement()
                .accessibilityLabel("Platter")
            }
            if let onSkip {
                HStack {
                    Spacer()
                    Button("Skip", action: onSkip)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.bodyText)
                        .frame(height: 44)
                        .accessibilityHint("Skips to sign in")
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Page dots directly above the primary button: current page is a 20×6 sage
/// capsule, the rest are 6×6 inactive-dot circles, 8pt apart.
struct OnboardingPageDots: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<total, id: \.self) { i in
                if i == current {
                    Capsule().fill(Color.accentColor).frame(width: 20, height: 6)
                } else {
                    Circle().fill(Color.inactiveDot).frame(width: 6, height: 6)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: current)
        .accessibilityElement()
        .accessibilityLabel("Page \(current + 1) of \(total)")
    }
}

/// The one primary button shape, used identically on every screen: 56pt tall,
/// 16pt radius, sage fill, white semibold. The label uses `.headline` so it
/// participates in Dynamic Type, clamping only at the largest sizes.
struct OnboardingPrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Centred body copy: scales with Dynamic Type, 1.5 line height, body-text
/// colour, wraps (never clips), 28pt side padding.
private struct OnboardingBody: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .lineSpacing(6)
            .foregroundStyle(Color.bodyText)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 28)
    }
}

/// Scales a view down (never up) so its laid-out height fits `maxHeight`,
/// reclaiming the freed vertical space (unlike a bare `.scaleEffect`). Used to
/// shrink the screen-2 illustration on short devices so the copy still fits.
private struct ScaleToFitHeight: ViewModifier {
    let maxHeight: CGFloat
    @State private var natural: CGFloat = 0

    func body(content: Content) -> some View {
        let scale = (natural > maxHeight && natural > 0) ? maxHeight / natural : 1
        content
            .background(GeometryReader { geo in
                Color.clear.preference(key: HeightPreferenceKey.self, value: geo.size.height)
            })
            .onPreferenceChange(HeightPreferenceKey.self) { natural = $0 }
            .scaleEffect(scale, anchor: .center)
            .frame(height: natural > 0 ? natural * scale : nil)
    }

    private struct HeightPreferenceKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }
}

private extension View {
    func scaleToFitHeight(_ maxHeight: CGFloat) -> some View {
        modifier(ScaleToFitHeight(maxHeight: maxHeight))
    }
}

/// A flow layout that wraps its subviews onto new lines (used for pantry chips).
struct WrapLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0; y += rowHeight + lineSpacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        let width = maxWidth.isFinite ? maxWidth : max(x - spacing, 0)
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0; y += rowHeight + lineSpacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                       proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - 1. Promise

struct OnboardingPromiseScreen: View {
    let page: Int
    let total: Int
    let onSkip: () -> Void
    let onContinue: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        OnboardingScaffold(page: page, total: total, showsLockup: true, onSkip: onSkip) { screenHeight in
            VStack(spacing: 0) {
                if !typeSize.isAccessibilitySize {
                    Image("defaultRecipeImage1")
                        .resizable()
                        .scaledToFill()
                        // Scale the hero to the device so it never crowds the
                        // copy on short screens (SE).
                        .frame(width: 300, height: min(260, screenHeight * 0.28))
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .accessibilityHidden(true)

                    Spacer().frame(height: 24)
                }

                VStack(spacing: 6) {
                    Text("Save the recipe.")
                        .font(.editorialTitle(size: 38, relativeTo: .largeTitle))
                        .foregroundStyle(Color.textPrimary)
                    Text("Cook it with what you've got.")
                        .font(.editorialTitle(size: 26, relativeTo: .title))
                        .foregroundStyle(Color.sageLight)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 28)

                Spacer().frame(height: 12)

                OnboardingBody(text: "Platter pulls recipes out of Reels, TikToks and blogs, then helps you cook with what's already in your kitchen.")
            }
            .padding(.vertical, 8)
        } bottom: {
            OnboardingPrimaryButton(title: "Get started", action: onContinue)
        }
    }
}

// MARK: - 2. Share to import

struct OnboardingShareScreen: View {
    let page: Int
    let total: Int
    let onSkip: () -> Void
    let onContinue: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        OnboardingScaffold(page: page, total: total, showsLockup: true, onSkip: onSkip) { screenHeight in
            VStack(spacing: 0) {
                if !typeSize.isAccessibilitySize {
                    ShareImportIllustration()
                        // Shrink the illustration on short devices (SE) so the
                        // headline and body still fit without scrolling.
                        .scaleToFitHeight(screenHeight < 700 ? 210 : .infinity)
                        .padding(.horizontal, 32)

                    Spacer().frame(height: 16)
                }

                Text("Share it to Platter.\nThat's the whole trick.")
                    .font(.editorialTitle(size: 34, relativeTo: .title))
                    .foregroundStyle(Color.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 28)

                Spacer().frame(height: 12)

                OnboardingBody(text: "From Instagram, TikTok or any recipe site, tap Share and pick Platter. We pull out the ingredients and steps for you.")
            }
            .padding(.vertical, 8)
        } bottom: {
            OnboardingPrimaryButton(title: "Continue", action: onContinue)
        }
    }
}

// MARK: - 3. Kitchen

struct OnboardingKitchenScreen: View {
    let page: Int
    let total: Int
    let onSkip: () -> Void
    let onContinue: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    private let pantry = ["Eggs", "Spinach", "Feta", "Rice", "Lemon", "Chickpeas"]

    var body: some View {
        OnboardingScaffold(page: page, total: total, showsLockup: true, onSkip: onSkip) { _ in
            VStack(spacing: 16) {
                if !typeSize.isAccessibilitySize {
                    kitchenPanel
                }

                VStack(spacing: 8) {
                    Text("Cook it with what you've got.")
                        .font(.editorialTitle(size: 34, relativeTo: .title))
                        .foregroundStyle(Color.textPrimary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 28)

                    OnboardingBody(text: "Add what's in your fridge and pantry. Platter finds recipes you can make with it, so less food goes to waste.")
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
        } bottom: {
            OnboardingPrimaryButton(title: "Continue", action: onContinue)
        }
    }

    // One compact panel: pantry chips, a hairline, then two "you could make"
    // rows. It is a decorative sample (accessibilityHidden), so its text is
    // capped at `.large` and it stays tight enough to fit alongside the copy.
    private var kitchenPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("In your pantry")

            WrapLayout(spacing: 8, lineSpacing: 8) {
                ForEach(pantry, id: \.self) { chip($0) }
            }
            .padding(.top, 8)

            Rectangle().fill(Color.hairline).frame(height: 1)
                .padding(.top, 10)
                .padding(.bottom, 10)

            sectionLabel("You could make")
                .padding(.bottom, 2)

            suggestionRow(thumb: "catRice1", title: "Lemon chickpea bowl",
                          subtitle: "Uses 4 of your items", showDivider: true)
            suggestionRow(thumb: "catBreakfast1", title: "Spinach & feta omelette",
                          subtitle: "Uses 3 of your items", showDivider: false)
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))
        .background(Color.surfacePanel, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .dynamicTypeSize(...DynamicTypeSize.large)
        .accessibilityElement()
        .accessibilityLabel("Example: with eggs, spinach, feta, rice, lemon and chickpeas in your pantry, Platter suggests a lemon chickpea bowl and a spinach and feta omelette.")
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .semibold))
            .tracking(0.96)   // 0.08em of 12pt
            .foregroundStyle(Color.dimLabel)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Color.chipText)
            .padding(.vertical, 5)
            .padding(.horizontal, 14)
            .background(Color.chipFill, in: Capsule())
    }

    private func suggestionRow(thumb: String, title: String, subtitle: String, showDivider: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(thumb)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.editorialTitle(size: 18, relativeTo: .headline))
                        .foregroundStyle(Color.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.claySubtitle)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)

            if showDivider {
                Rectangle().fill(Color.hairline).frame(height: 1)
            }
        }
    }
}

// MARK: - 4. Sign in

struct OnboardingSignInScreen: View {
    @ObservedObject var auth: AuthModel
    let page: Int
    let total: Int

    @Environment(\.dynamicTypeSize) private var typeSize

    // Terms falls back to Apple's standard app EULA until a Platter Terms page
    // exists; Privacy points at the live page.
    private let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    private let privacyURL = URL(string: "https://platterapp.tech/privacy")!

    var body: some View {
        OnboardingScaffold(page: page, total: total, showsLockup: false, onSkip: nil) { _ in
            VStack(spacing: 0) {
                if !typeSize.isAccessibilitySize {
                    PlatterMark(size: 88)
                        .accessibilityHidden(true)

                    Spacer().frame(height: 28)
                }

                Text("One account, every device.")
                    .font(.editorialTitle(size: 36, relativeTo: .largeTitle))
                    .foregroundStyle(Color.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 28)

                Spacer().frame(height: 14)

                OnboardingBody(text: "Sign in so your recipes, meal plan and grocery list follow you everywhere.")
            }
            .padding(.vertical, 8)
        } bottom: {
            VStack(spacing: 14) {
                AuthMethodsView(auth: auth, emailStyle: .disclosure, style: .onboarding)
                legal
            }
        }
    }

    private var legal: some View {
        Text(legalText)
            .font(.caption2)
            .foregroundStyle(Color.bodyText)
            .multilineTextAlignment(.center)
            .tint(Color.secondaryAccent)
    }

    private var legalText: AttributedString {
        var string = AttributedString("By continuing you agree to our ")
        var terms = AttributedString("Terms")
        terms.link = termsURL
        terms.underlineStyle = .single
        let mid = AttributedString(" and ")
        var privacy = AttributedString("Privacy Policy")
        privacy.link = privacyURL
        privacy.underlineStyle = .single
        let end = AttributedString(".")
        string.append(terms); string.append(mid); string.append(privacy); string.append(end)
        return string
    }
}
