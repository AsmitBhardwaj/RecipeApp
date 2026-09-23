//
//  PlatterProPaywallView.swift
//  Platter Pro paywall — near-black canvas, cream text, sage-green accent, coral
//  strike-through. Centered layout: badge → wordmark → two plan boxes (Monthly /
//  Yearly) → included-features list → pinned CTA.
//
//  Three states (loading / ready / unavailable) are modeled explicitly as
//  `PlanContent` so each renders deterministically and can be previewed and
//  screenshotted in isolation.
//
//  REAL PRICES COME FROM THE LIVE PRODUCT. The monthly/yearly base price and the
//  free-trial phrasing are mapped from the live `Product` (and its
//  `introductoryOffer`) in `cardData(for:…)`, so an App Store Connect price change
//  flows through without this view going stale. Yearly is $29.99/yr PERMANENTLY
//  with a 7-day free trial — there is no discounted-first-year path. The one
//  figure that is intentionally NOT a real price is the struck-through "$45/yr" on
//  the Yearly box: a fixed round marketing anchor (see `yearlyCompareAtDisplay`),
//  display-only. The "Save X%" badge is computed from the REAL prices
//  (1 − yearly ÷ monthly×12), NOT from that anchor, so it stays honest to actual
//  pricing. Sample prices live only in the DEBUG harness/previews. Purchase/
//  entitlement logic is unchanged: selection is a productID resolved back to the
//  live `Product` for `SubscriptionService.purchase`.
//

import StoreKit
import SwiftUI

// MARK: - Palette (fixed brand colors for this screen, light/dark independent)

private extension Color {
    static let ppBackground = Color(red: 0x17 / 255, green: 0x16 / 255, blue: 0x0F / 255)
    static let ppCream = Color(red: 0xF5 / 255, green: 0xEC / 255, blue: 0xDD / 255)
    static let ppGreen = Color(red: 0x7C / 255, green: 0x98 / 255, blue: 0x68 / 255)
    static let ppCoral = Color(red: 0xC9 / 255, green: 0x7A / 255, blue: 0x5A / 255)
}

// MARK: - View state

/// Display data for one plan card, mapped from a `Product` (or injected for
/// previews/QA). `id` is the StoreKit productID used to resolve the real
/// `Product` at purchase time. Every price string here is already
/// locale-formatted (`Product.displayPrice` / `SubscriptionOffer.displayPrice`).
struct PlanCardData: Identifiable, Equatable {
    let id: String
    let periodNoun: String          // "MONTHLY" / "YEARLY"
    let headlinePrice: String       // the big number — the plan's real base price
    let periodSuffix: String        // "/mo" / "/yr"
    let strikethroughPrice: String? // Yearly's fixed display anchor, e.g. "$45/yr"
    let saveBadgeText: String?      // "Save 64%" — computed as 1 − yearly ÷ monthly×12
    let subtitle: String            // "Billed monthly" / "7-day free trial"
    let trialText: String?          // "7 days free" when a free-trial intro exists
}

enum PlanContent: Equatable {
    case loading
    case ready([PlanCardData])
    case unavailable
}

struct PlatterProPaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var subscriptions: SubscriptionService

    @State private var selectedProductID: String?

    /// Preview/screenshot override. `nil` in production, where content is derived
    /// from the live `SubscriptionService`.
    private let forcedContent: PlanContent?

    init(forcedContent: PlanContent? = nil) {
        self.forcedContent = forcedContent
    }

    // MARK: Derived state

    private var planContent: PlanContent {
        if let forcedContent { return forcedContent }
        if !subscriptions.products.isEmpty { return .ready(planData) }
        if subscriptions.productLoadError != nil { return .unavailable }
        return .loading
    }

    private var planData: [PlanCardData] {
        let products = subscriptions.products
        // Monthly-equivalent annual spend, used to compute the Yearly "Save X%"
        // badge (1 − yearly ÷ monthly×12). Read from the live monthly product.
        let monthlyPerYear: Decimal? = products
            .first { $0.subscription?.subscriptionPeriod.unit == .month }
            .map { $0.price * 12 }
        return products.map { Self.cardData(for: $0, monthlyEquivalentPerYear: monthlyPerYear) }
    }

    private var readyPlans: [PlanCardData] {
        if case .ready(let plans) = planContent { return plans }
        return []
    }

    private var selectedPlan: PlanCardData? {
        readyPlans.first { $0.id == selectedProductID }
    }

    private var canPurchase: Bool {
        if case .ready = planContent {
            return selectedProductID != nil && subscriptions.purchaseState != .purchasing
        }
        return false
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                badge
                wordmark
                plansSection
                includedSection
                purchaseStatus
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Color.ppBackground.ignoresSafeArea())
        .foregroundStyle(Color.ppCream)
        .safeAreaInset(edge: .top, spacing: 0) { restoreBar }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        // Select the default plan immediately so a forced/already-loaded ready
        // state has a selection (and an enabled CTA) without waiting on the
        // StoreKit fetch below.
        .onAppear(perform: selectDefaultPlanIfNeeded)
        .task { await subscriptions.start() }
        .onChange(of: readyPlans.map(\.id)) { _, _ in selectDefaultPlanIfNeeded() }
        .onChange(of: subscriptions.purchaseState) { _, state in
            if state == .succeeded && subscriptions.hasProAccess { dismiss() }
        }
    }

    // MARK: Restore link (top-right, low emphasis). The paywall is always shown
    // as a sheet, so swipe-down handles dismissal — there is no ✕ by design.

    private var restoreBar: some View {
        HStack {
            Spacer()
            Button("Restore") {
                Task { await subscriptions.restorePurchases() }
            }
            .font(.system(size: 14))
            .foregroundStyle(Color.ppCream.opacity(0.6))
            .disabled(subscriptions.purchaseState == .purchasing)
            .frame(minHeight: 44)
        }
        .padding(.horizontal, 20)
        .background(Color.ppBackground)
    }

    // MARK: Badge + wordmark

    private var badge: some View {
        Text("P")
            .font(.editorialTitle(size: 36, relativeTo: .largeTitle))
            .foregroundStyle(Color.ppCream)
            .frame(width: 70, height: 70)
            .background(Color.ppGreen, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .accessibilityHidden(true)
    }

    private var wordmark: some View {
        (
            Text("Platter ").font(.editorialTitle(size: 27, relativeTo: .title))
            + Text("Pro").font(.scriptAccentItalic(size: 27, relativeTo: .title))
        )
        .foregroundStyle(Color.ppGreen)
        .accessibilityElement()
        .accessibilityLabel("Platter Pro")
    }

    // MARK: Plans

    @ViewBuilder
    private var plansSection: some View {
        switch planContent {
        case .loading:
            HStack(alignment: .top, spacing: 12) {
                skeletonCard
                skeletonCard
            }
        case .ready(let plans):
            // Display order is Monthly (left) then Yearly (right) to match the
            // design, independent of the product ordering used elsewhere.
            HStack(alignment: .top, spacing: 12) {
                ForEach(Self.displayOrdered(plans)) { plan in
                    planCard(plan)
                }
            }
        case .unavailable:
            unavailablePanel
        }
    }

    private func planCard(_ plan: PlanCardData) -> some View {
        let isSelected = selectedProductID == plan.id
        return Button {
            subscriptions.clearPurchaseMessage()
            if reduceMotion {
                selectedProductID = plan.id
            } else {
                withAnimation(.easeInOut(duration: 0.15)) { selectedProductID = plan.id }
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Text(plan.periodNoun)
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(Color.ppCream.opacity(0.6))
                    Spacer(minLength: 8)
                    radio(isSelected: isSelected)
                }

                Spacer(minLength: 14)

                if let struck = plan.strikethroughPrice {
                    Text(struck)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.ppCoral)
                        .strikethrough(true, color: Color.ppCoral)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }

                Text(plan.headlinePrice + plan.periodSuffix)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.ppCream)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(.top, 1)

                Text(plan.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ppCream.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
            .background(Color.ppCream.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(isSelected ? Color.ppGreen : Color.ppCream.opacity(0.12),
                                  lineWidth: isSelected ? 1.5 : 1)
            }
            .overlay(alignment: .topTrailing) {
                if let save = plan.saveBadgeText {
                    Text(save)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.ppBackground)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.ppGreen, in: Capsule())
                        .offset(x: 6, y: -10)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(for: plan))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func radio(isSelected: Bool) -> some View {
        ZStack {
            Circle()
                .strokeBorder(isSelected ? Color.ppGreen : Color.ppCream.opacity(0.4), lineWidth: 1.5)
                .frame(width: 22, height: 22)
            if isSelected {
                Circle().fill(Color.ppGreen).frame(width: 22, height: 22)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .accessibilityHidden(true)
    }

    private func accessibilityLabel(for plan: PlanCardData) -> String {
        var parts = [plan.periodNoun.capitalized, plan.headlinePrice + plan.periodSuffix, plan.subtitle]
        if let save = plan.saveBadgeText { parts.append(save) }
        if let trial = plan.trialText { parts.append(trial) }
        return parts.joined(separator: ", ")
    }

    private var skeletonCard: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.ppCream.opacity(0.05))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.ppCream.opacity(0.12), lineWidth: 1)
            }
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 10) {
                    Capsule().fill(Color.ppCream.opacity(0.12)).frame(width: 60, height: 10)
                    Spacer(minLength: 20)
                    Capsule().fill(Color.ppCream.opacity(0.12)).frame(width: 84, height: 20)
                    Capsule().fill(Color.ppCream.opacity(0.12)).frame(width: 56, height: 10)
                }
                .padding(16)
            }
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
            .accessibilityHidden(true)
    }

    private var unavailablePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Plans couldn't load")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.ppCream)
            Text("Check your connection and try again.")
                .font(.system(size: 14))
                .foregroundStyle(Color.ppCream.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            Button("Try Again") {
                Task {
                    await subscriptions.reloadProductsAndEntitlement()
                    selectDefaultPlanIfNeeded()
                }
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.ppGreen)
            .frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .leading)
        .padding(16)
        .background(Color.ppCream.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.ppCream.opacity(0.12), lineWidth: 1)
        }
    }

    // MARK: Included features

    private var includedSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            (
                Text("What's included with ").font(.system(size: 15, weight: .semibold))
                + Text("Pro").font(.scriptAccentItalic(size: 15, relativeTo: .subheadline))
                    .foregroundColor(.ppGreen)
            )
            .foregroundStyle(Color.ppCream)
            .frame(maxWidth: .infinity, alignment: .leading)

            featureRow("Plan a full week on your budget")
            featureRow("Recipes from your pantry")
            featureRow("Calories & macros on every recipe")
            featureRow("Unlimited recipe imports")
            featureRow("Grocery lists grouped by aisle")
            featureRow("Organize recipes into cookbooks")
        }
        .padding(.top, 2)
    }

    private func featureRow(_ text: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "checkmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.ppGreen)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(Color.ppCream)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Purchase status (inline, above the pinned bar)

    @ViewBuilder
    private var purchaseStatus: some View {
        if let message = subscriptions.purchaseState.message {
            Text(message)
                .font(.footnote)
                .foregroundStyle(subscriptions.purchaseState.isError ? Color.ppCoral : Color.ppCream.opacity(0.7))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Pinned bottom bar

    private var bottomBar: some View {
        VStack(spacing: 12) {
            if let caption = ctaCaption {
                Text(caption)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ppCream.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            purchaseButton
            legalRow
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Color.ppBackground)
    }

    /// The small line above the CTA. Derived from the selected plan's live
    /// pricing/offer, so it can never contradict the plan boxes. The base price is
    /// permanent (no "first year" discount), so a trial just precedes the price.
    private var ctaCaption: String? {
        guard let plan = selectedPlan else { return nil }
        let word = plan.periodSuffix == "/yr" ? "year" : (plan.periodSuffix == "/mo" ? "month" : "period")
        if let trial = plan.trialText {
            return "\(trial), then \(plan.headlinePrice)/\(word) — cancel anytime"
        }
        return "\(plan.headlinePrice)/\(word) — cancel anytime"
    }

    /// Trial-aware CTA copy: the free-trial plan (Yearly) leads with the trial;
    /// a no-trial plan (Monthly) keeps the plain upgrade wording so the button is
    /// never misleading about a free week the selected plan doesn't offer.
    private var purchaseButtonTitle: String {
        if subscriptions.purchaseState == .purchasing { return "Working…" }
        return selectedPlan?.trialText != nil ? "Start Your Free Week" : "Continue with Pro"
    }

    private var purchaseButton: some View {
        Button {
            guard let id = selectedProductID,
                  let product = subscriptions.products.first(where: { $0.id == id }) else { return }
            Task { await subscriptions.purchase(product) }
        } label: {
            HStack(spacing: 8) {
                if subscriptions.purchaseState == .purchasing {
                    ProgressView().tint(Color.ppBackground)
                }
                Text(purchaseButtonTitle)
                    .font(.system(size: 17, weight: .bold))
            }
            .foregroundStyle(Color.ppBackground)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Color.ppCream.opacity(canPurchase ? 1 : 0.4),
                        in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!canPurchase)
        .accessibilityHint("Begins the App Store purchase for the selected subscription")
    }

    private var legalRow: some View {
        HStack(spacing: 24) {
            Link("Terms of Service", destination: SubscriptionConfiguration.termsURL)
            Link("Privacy Policy", destination: SubscriptionConfiguration.privacyURL)
        }
        .font(.system(size: 12))
        .foregroundStyle(Color.ppCream.opacity(0.6))
        .frame(maxWidth: .infinity)
        .frame(minHeight: 32)
    }

    // MARK: Helpers

    private func selectDefaultPlanIfNeeded() {
        let plans = readyPlans
        guard !plans.isEmpty else { return }
        // Preselect yearly (the first ordered product is yearly — see
        // SubscriptionConfiguration.orderedProductIDs); fall back to the first.
        if selectedProductID == nil || !plans.contains(where: { $0.id == selectedProductID }) {
            let yearly = plans.first { $0.periodSuffix == "/yr" }
            selectedProductID = yearly?.id ?? plans.first?.id
        }
    }

    /// Orders plan cards for display: Monthly, then Yearly, then anything else,
    /// preserving relative order within each bucket.
    private static func displayOrdered(_ plans: [PlanCardData]) -> [PlanCardData] {
        func rank(_ suffix: String) -> Int {
            switch suffix {
            case "/mo": return 0
            case "/yr": return 1
            default: return 2
            }
        }
        return plans.enumerated().sorted { lhs, rhs in
            let (li, lp) = lhs, (ri, rp) = rhs
            let lr = rank(lp.periodSuffix), rr = rank(rp.periodSuffix)
            return lr == rr ? li < ri : lr < rr
        }.map(\.element)
    }

    // MARK: Product → card mapping (the only place real prices are read)

    /// The struck-through comparison price on the Yearly box. A deliberate ROUND
    /// marketing anchor — NOT a configured/real price. Platter Pro Yearly is
    /// $29.99/yr permanently, so there is no real price to strike; this anchor is
    /// intentionally hardcoded here rather than read from StoreKit. USD-literal — a
    /// non-USD storefront would show this verbatim (revisit if pricing localizes).
    /// NOTE: this anchor is display-only; the "Save X%" badge is computed from the
    /// real monthly×12, NOT from this anchor, so the strike and the badge express
    /// two different comparisons by design.
    static let yearlyCompareAtDisplay = "$45"

    static func cardData(for product: Product, monthlyEquivalentPerYear: Decimal?) -> PlanCardData {
        let unit = product.subscription?.subscriptionPeriod.unit
        let noun: String
        let suffix: String
        switch unit {
        case .year:  noun = "YEARLY";  suffix = "/yr"
        case .month: noun = "MONTHLY"; suffix = "/mo"
        case .week:  noun = "WEEKLY";  suffix = "/wk"
        case .day:   noun = "DAILY";   suffix = "/day"
        default:     noun = "PLAN";    suffix = ""
        }

        let headline = trimmedPrice(product.displayPrice)  // real, permanent base price
        var subtitle = unit == .month ? "Billed monthly" : "Billed annually"
        var trial: String?

        // A free-trial introductory offer drives the trial copy (CTA caption) and
        // the box's status line. Platter Pro configures a 7-day free trial on
        // Yearly; the $29 base is permanent, so there is NO discounted-first-period
        // path any more.
        if let offer = product.subscription?.introductoryOffer, offer.paymentMode == .freeTrial {
            trial = trialText(from: offer.period)
            subtitle = trialStatusLine(from: offer.period)
        }

        // The Yearly box shows the fixed struck comparison anchor ($45) plus a
        // "Save X%" badge computed from the REAL prices (1 − yearly ÷ monthly×12),
        // NOT from the anchor — so the badge stays honest to actual pricing.
        var strikethrough: String?
        var saveBadge: String?
        if unit == .year {
            strikethrough = yearlyCompareAtDisplay + suffix
            if let monthlyPerYear = monthlyEquivalentPerYear {
                saveBadge = savePercent(discounted: product.price, regular: monthlyPerYear)
            }
        }

        return PlanCardData(
            id: product.id,
            periodNoun: noun,
            headlinePrice: headline,
            periodSuffix: suffix,
            strikethroughPrice: strikethrough,
            saveBadgeText: saveBadge,
            subtitle: subtitle,
            trialText: trial
        )
    }

    /// Drops a trailing ".00" so a whole-dollar price reads "$29", not "$29.00".
    /// Locale-safe: only the exact ".00" suffix (US/en formatting) is trimmed; any
    /// other format (e.g. "29,00 €") is left untouched.
    private static func trimmedPrice(_ display: String) -> String {
        display.hasSuffix(".00") ? String(display.dropLast(3)) : display
    }

    private static func savePercent(discounted: Decimal, regular: Decimal) -> String? {
        guard regular > 0, discounted < regular else { return nil }
        let fraction = (regular - discounted) / regular
        let percent = Int(((fraction as NSDecimalNumber).doubleValue * 100).rounded())
        guard percent > 0 else { return nil }
        return "Save \(percent)%"
    }

    /// Short trial copy for the CTA caption, e.g. "7 days free".
    private static func trialText(from period: Product.SubscriptionPeriod) -> String {
        let n = period.value
        switch period.unit {
        case .day:   return "\(n) \(n == 1 ? "day" : "days") free"
        case .week:  return "\(n * 7) days free"
        case .month: return "\(n) \(n == 1 ? "month" : "months") free"
        case .year:  return "\(n) \(n == 1 ? "year" : "years") free"
        @unknown default: return "Free trial"
        }
    }

    /// The Yearly box's status line, e.g. "7-day free trial".
    private static func trialStatusLine(from period: Product.SubscriptionPeriod) -> String {
        switch period.unit {
        case .day:   return "\(period.value)-day free trial"
        case .week:  return "\(period.value * 7)-day free trial"
        case .month: return "\(period.value)-month free trial"
        case .year:  return "\(period.value)-year free trial"
        @unknown default: return "Free trial"
        }
    }
}

private extension SubscriptionService.PurchaseState {
    var isError: Bool {
        switch self {
        case .failed, .unverified: return true
        default: return false
        }
    }
}

// MARK: - Previews

/// Sample data mirroring what production renders from the live products (Yearly
/// $29.99/yr permanent with a 7-day free trial; Monthly $6.99/mo). The struck
/// "$45" is the fixed display-only comparison anchor (see `yearlyCompareAtDisplay`);
/// the "Save X%" badge is computed from the real prices — 1 − 29.99/(6.99×12) ≈
/// 64%. Illustrative for previews/QA — production derives all of this via `cardData`.
extension PlanCardData {
    static let sampleYearly = PlanCardData(
        id: "preview.yearly",
        periodNoun: "YEARLY",
        headlinePrice: "$29.99",
        periodSuffix: "/yr",
        strikethroughPrice: "$45/yr",
        saveBadgeText: "Save 64%",
        subtitle: "7-day free trial",
        trialText: "7 days free"
    )
    static let sampleMonthly = PlanCardData(
        id: "preview.monthly",
        periodNoun: "MONTHLY",
        headlinePrice: "$6.99",
        periodSuffix: "/mo",
        strikethroughPrice: nil,
        saveBadgeText: nil,
        subtitle: "Billed monthly",
        trialText: nil
    )
}

#Preview("Ready") {
    PlatterProPaywallView(forcedContent: .ready([.sampleYearly, .sampleMonthly]))
        .environmentObject(SubscriptionService())
}

#Preview("Loading") {
    PlatterProPaywallView(forcedContent: .loading)
        .environmentObject(SubscriptionService())
}

#Preview("Unavailable") {
    PlatterProPaywallView(forcedContent: .unavailable)
        .environmentObject(SubscriptionService())
}
