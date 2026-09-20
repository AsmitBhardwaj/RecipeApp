//
//  PaywallView.swift
//  RecipeApp
//
//  The Platter Pro paywall: a full-screen dark sheet with a torn-edge hero
//  photo, headline/subhead (per trigger), three benefit rows, Annual + Monthly
//  plan cards, a primary CTA, fine print, and a Restore / Terms / Privacy
//  footer. All prices/copy come from PaywallModel (→ RecipeKit); this file is
//  presentation only. Depends on the paywall protocols, never on RevenueCat.
//

import SwiftUI
import SafariServices
import RecipeKit

struct PaywallView: View {
    @StateObject private var model: PaywallModel
    @Environment(\.dismiss) private var dismiss
    @State private var webLink: WebLink?

    /// Hero photo: an existing `main` asset (plated dish, reads well on dark).
    private let heroAsset = "defaultRecipeImage1"

    init(
        trigger: PaywallTrigger,
        entitlements: any EntitlementProviding,
        purchasing: any PaywallPurchasing,
        initialPeriod: PaywallPeriod = .annual
    ) {
        _model = StateObject(wrappedValue: PaywallModel(
            trigger: trigger, entitlements: entitlements, purchasing: purchasing, initialPeriod: initialPeriod))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                hero
                VStack(spacing: 24) {
                    headerBlock
                    benefitsBlock
                    plansBlock
                    ctaBlock
                    footer
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .background(Color.appBackground.ignoresSafeArea())
        .preferredColorScheme(.dark)                 // paywall is always dark
        .task { await model.load() }
        .onChange(of: model.didFinish) { _, done in if done { dismiss() } }
        .sheet(item: $webLink) { link in SafariView(url: link.url).ignoresSafeArea() }
        .overlay(alignment: .top) { restoreToast }
    }

    // MARK: Hero + close

    private var hero: some View {
        Image(heroAsset)
            .resizable()
            .scaledToFill()
            .frame(height: 220)
            .frame(maxWidth: .infinity)
            .clipped()
            .clipShape(PaywallTornEdge())
            .ignoresSafeArea(edges: .top)
            .accessibilityHidden(true)
            .overlay(alignment: .topLeading) {
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)                 // 44pt target
                        .background(.black.opacity(0.35), in: Circle())
                }
                .padding(.leading, 16)
                .padding(.top, 8)
                .accessibilityLabel("Close")
            }
    }

    // MARK: Header

    private var headerBlock: some View {
        VStack(spacing: 10) {
            Text(model.headline)
                .font(.editorialTitle(size: 30, relativeTo: .largeTitle))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.textPrimary)
            Text(model.subhead)
                .font(.callout)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Benefits (sage check + text, no boxes, no numbers)

    private var benefitsBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(model.benefits, id: \.self) { benefit in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .font(.headline)
                    Text(benefit)
                        .font(.body)
                        .foregroundStyle(Color.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Plans

    private var plansBlock: some View {
        VStack(spacing: 12) {
            switch model.loadState {
            case .loading:
                ProgressView().controlSize(.large).frame(maxWidth: .infinity, minHeight: 160)
            case .failed:
                VStack(spacing: 10) {
                    Text("Couldn't load subscription options.").font(.callout).foregroundStyle(Color.textSecondary)
                    Button("Try again") { Task { await model.load() } }.foregroundStyle(Color.accentColor)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            case .loaded:
                if let offering = model.offering {
                    PaywallPlanCard(
                        title: "Annual",
                        subtitle: model.annualCardSubtitle,
                        price: "\(offering.annual.localizedPrice)/yr",
                        savingsPercent: model.savingsPercent,
                        isSelected: model.selectedPeriod == .annual,
                        action: { model.select(.annual) }
                    )
                    PaywallPlanCard(
                        title: "Monthly",
                        subtitle: PaywallCopy.monthlyCardSubtitle(),
                        price: "\(offering.monthly.localizedPrice)/mo",
                        savingsPercent: nil,
                        isSelected: model.selectedPeriod == .monthly,
                        action: { model.select(.monthly) }
                    )
                }
            }
        }
    }

    // MARK: CTA + fine print

    private var ctaBlock: some View {
        VStack(spacing: 10) {
            if let error = model.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: { Task { await model.purchase() } }) {
                Group {
                    if model.isPurchasing {
                        ProgressView().tint(.white)
                    } else {
                        Text(model.ctaTitle).font(.headline)
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 52)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .disabled(model.loadState != .loaded || model.isPurchasing)
            .opacity(model.loadState == .loaded ? 1 : 0.5)

            Text(model.finePrint)
                .font(.caption2)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Footer

    private var footer: some View {
        // Wraps to multiple lines at large Dynamic Type via a flexible HStack of
        // buttons that each keep a 44pt target.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) { restoreButton; dot; termsButton; dot; privacyButton }
            VStack(spacing: 8) { restoreButton; termsButton; privacyButton }
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(Color.textSecondary)
    }

    private var dot: some View { Text("·").foregroundStyle(Color.textSecondary.opacity(0.6)) }

    private var restoreButton: some View {
        Button("Restore Purchases") { Task { await model.restore() } }
            .frame(minHeight: 44)
            .foregroundStyle(Color.textPrimary)
    }
    private var termsButton: some View {
        Button("Terms") { webLink = WebLink(url: PaywallLinks.terms) }
            .frame(minHeight: 44)
    }
    private var privacyButton: some View {
        Button("Privacy") { webLink = WebLink(url: PaywallLinks.privacy) }
            .frame(minHeight: 44)
    }

    @ViewBuilder private var restoreToast: some View {
        if let msg = model.restoreMessage {
            Text(msg)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color.accentColor, in: Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: - Plan card

struct PaywallPlanCard: View {
    let title: String
    let subtitle: String
    let price: String
    let savingsPercent: Int?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle().strokeBorder(isSelected ? Color.accentColor : Color.cardEdge, lineWidth: 2)
                        .frame(width: 24, height: 24)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .resizable().frame(width: 24, height: 24)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).foregroundStyle(Color.textPrimary)
                    Text(subtitle).font(.subheadline).foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(price).font(.headline).foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(isSelected ? Color.accentColor : Color.cardEdge, lineWidth: isSelected ? 2 : 1)
            )
            .overlay(alignment: .top) {
                if let pct = savingsPercent {
                    Text("SAVE \(pct)%")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(Color.secondaryAccent, in: Capsule())
                        .offset(y: -10)
                        .accessibilityHidden(true)   // folded into the card's label
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11yLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var a11yLabel: String {
        var parts = ["\(title) plan", subtitle, price]
        if let pct = savingsPercent { parts.append("save \(pct) percent") }
        if isSelected { parts.append("selected") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Torn hero edge

/// Rectangle with a torn/perforated bottom edge (cream shows through beneath).
struct PaywallTornEdge: Shape {
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
            p.addLine(to: CGPoint(x: max(x, 0), y: rect.maxY - (down ? 0 : depth)))
            down.toggle()
        }
        p.addLine(to: CGPoint(x: 0, y: 0))
        p.closeSubpath()
        return p
    }
}

// MARK: - Links + Safari

enum PaywallLinks {
    static let privacy = URL(string: "https://platterapp.tech/privacy")!
    // TODO(platter): no Terms page exists yet — falling back to Apple's standard
    // EULA. Point this at platterapp.tech/terms once that page is live.
    static let terms = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
}

struct WebLink: Identifiable { let url: URL; var id: String { url.absoluteString } }

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

// MARK: - Previews

#Preview("importLimit · trial") {
    PaywallView(trigger: .importLimit,
                entitlements: MockEntitlementProvider(freeImportLimit: 10),
                purchasing: MockPaywallPurchasing(scenario: .trialEligible))
}

#Preview("pantry · trial") {
    PaywallView(trigger: .pantry,
                entitlements: MockEntitlementProvider(),
                purchasing: MockPaywallPurchasing(scenario: .trialEligible))
}

#Preview("settings · not eligible") {
    PaywallView(trigger: .settings,
                entitlements: MockEntitlementProvider(),
                purchasing: MockPaywallPurchasing(scenario: .notTrialEligible))
}

#Preview("importLimit · AX5") {
    PaywallView(trigger: .importLimit,
                entitlements: MockEntitlementProvider(freeImportLimit: 10),
                purchasing: MockPaywallPurchasing(scenario: .trialEligible))
        .environment(\.dynamicTypeSize, .accessibility5)
}
