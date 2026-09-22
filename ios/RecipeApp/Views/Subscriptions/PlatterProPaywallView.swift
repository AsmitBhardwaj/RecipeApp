//
//  PlatterProPaywallView.swift
//  PlatterPro paywall — warm ivory, espresso text, forest-green accent, pale-sage
//  selection. Left-aligned, ~24pt margins, no gradients/shadows/decoration.
//
//  Three states (loading / ready / unavailable) are modeled explicitly as
//  `PlanContent` so each renders deterministically and can be previewed and
//  screenshotted in isolation. Prices always come from `Product.displayPrice`
//  (mapped into `PlanCardData` for display) — never hardcoded in the ready path.
//  Purchase/entitlement logic is unchanged: selection is a productID that
//  resolves back to the live `Product` for `SubscriptionService.purchase`.
//

import StoreKit
import SwiftUI

// MARK: - View state

/// Display data for one plan card, mapped from a `Product` (or injected for
/// previews). `id` is the StoreKit productID used to resolve the real `Product`
/// at purchase time.
struct PlanCardData: Identifiable, Equatable {
    let id: String
    let name: String        // "Yearly" / "Monthly"
    let price: String       // Product.displayPrice
    let periodLabel: String // "per year" / "per month"
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
        subscriptions.products.map { product in
            let unit = product.subscription?.subscriptionPeriod.unit
            return PlanCardData(
                id: product.id,
                name: Self.name(for: unit),
                price: product.displayPrice,
                periodLabel: Self.periodLabel(for: unit)
            )
        }
    }

    private var readyPlans: [PlanCardData] {
        if case .ready(let plans) = planContent { return plans }
        return []
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
            VStack(alignment: .leading, spacing: 22) {
                headline
                benefits
                plansSection
                purchaseStatus
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .padding(.bottom, 20)
        }
        .background(Color.creamTint.ignoresSafeArea())
        .foregroundStyle(Color.textPrimary)
        .safeAreaInset(edge: .top, spacing: 0) { closeBar }
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

    // MARK: Close button

    private var closeBar: some View {
        HStack {
            Spacer()
            Button(action: dismiss.callAsFunction) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Color.surface, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(Color.creamTint)
    }

    // MARK: Headline (serif + script)

    private var headline: some View {
        VStack(alignment: .leading, spacing: -4) {
            Text("Cook with")
                .font(.editorialTitle(size: 40, relativeTo: .largeTitle))
                .foregroundStyle(Color.textPrimary)
            Text("confidence.")
                .font(.scriptAccent(size: 46, relativeTo: .largeTitle))
                .foregroundStyle(Color.accentColor)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Cook with confidence.")
        .padding(.top, 4)
    }

    // MARK: Benefits

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 14) {
            benefitRow("infinity", "Unlimited imports", "Save as many recipes as you like.")
            benefitRow("cabinet", "Cook from your pantry", "Recipes that use what you already have.")
            benefitRow("leaf", "Know what's in every meal", "Estimated calories and macros on each recipe.")
            benefitRow("creditcard", "Plan around your budget", "A weekly plan that fits what you spend.")
        }
    }

    private func benefitRow(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .background(Color.sageLight.opacity(0.42), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
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
            HStack(alignment: .top, spacing: 12) {
                ForEach(plans) { plan in
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
                    Text(plan.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                    Spacer(minLength: 8)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.textSecondary.opacity(0.5))
                        .accessibilityHidden(true)
                }

                Spacer(minLength: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.price)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Color.textPrimary)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                    Text(plan.periodLabel)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.textSecondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
            .background(isSelected ? Color.sageLight.opacity(0.42) : Color.surface,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.hairline,
                                  lineWidth: isSelected ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(plan.name), \(plan.price) \(plan.periodLabel)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var skeletonCard: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.surface)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.hairline, lineWidth: 1)
            }
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 10) {
                    Capsule().fill(Color.hairline).frame(width: 64, height: 12)
                    Spacer(minLength: 20)
                    Capsule().fill(Color.hairline).frame(width: 84, height: 20)
                    Capsule().fill(Color.hairline).frame(width: 48, height: 10)
                }
                .padding(16)
            }
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
            .accessibilityHidden(true)
    }

    private var unavailablePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Plans couldn't load")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
            Text("Check your connection and try again.")
                .font(.system(size: 14))
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try Again") {
                Task {
                    await subscriptions.reloadProductsAndEntitlement()
                    selectDefaultPlanIfNeeded()
                }
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .leading)
        .padding(16)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.hairline, lineWidth: 1)
        }
    }

    // MARK: Purchase status (inline, above the pinned bar)

    @ViewBuilder
    private var purchaseStatus: some View {
        if let message = subscriptions.purchaseState.message {
            Text(message)
                .font(.footnote)
                .foregroundStyle(subscriptions.purchaseState.isError ? .red : Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Pinned bottom bar

    private var bottomBar: some View {
        VStack(spacing: 12) {
            purchaseButton
            legalRow
            Text("Payment is charged to your Apple Account when confirmed. Renews automatically unless canceled at least 24 hours before the period ends.")
                .font(.system(size: 12))
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Color.creamTint)
    }

    private var purchaseButton: some View {
        Button {
            guard let id = selectedProductID,
                  let product = subscriptions.products.first(where: { $0.id == id }) else { return }
            Task { await subscriptions.purchase(product) }
        } label: {
            HStack(spacing: 8) {
                if subscriptions.purchaseState == .purchasing {
                    ProgressView().tint(.white)
                }
                Text(subscriptions.purchaseState == .purchasing ? "Working…" : "Start Platter Pro")
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Color.accentColor.opacity(canPurchase ? 1 : 0.4),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canPurchase)
        .accessibilityHint("Begins the App Store purchase for the selected subscription")
    }

    private var legalRow: some View {
        HStack {
            Button("Restore Purchases") {
                Task { await subscriptions.restorePurchases() }
            }
            .disabled(subscriptions.purchaseState == .purchasing)
            Spacer(minLength: 8)
            Link("Terms of Use", destination: SubscriptionConfiguration.termsURL)
            Spacer(minLength: 8)
            Link("Privacy Policy", destination: SubscriptionConfiguration.privacyURL)
        }
        .font(.system(size: 13))
        .foregroundStyle(Color.accentColor)
        .frame(minHeight: 44)
    }

    // MARK: Helpers

    private func selectDefaultPlanIfNeeded() {
        let plans = readyPlans
        guard !plans.isEmpty else { return }
        // Preselect yearly (the first ordered product is yearly — see
        // SubscriptionConfiguration.orderedProductIDs); fall back to the first.
        if selectedProductID == nil || !plans.contains(where: { $0.id == selectedProductID }) {
            let yearly = plans.first { $0.periodLabel == "per year" }
            selectedProductID = yearly?.id ?? plans.first?.id
        }
    }

    private static func name(for unit: Product.SubscriptionPeriod.Unit?) -> String {
        switch unit {
        case .year: return "Yearly"
        case .month: return "Monthly"
        case .week: return "Weekly"
        case .day: return "Daily"
        default: return "Plan"
        }
    }

    private static func periodLabel(for unit: Product.SubscriptionPeriod.Unit?) -> String {
        switch unit {
        case .year: return "per year"
        case .month: return "per month"
        case .week: return "per week"
        case .day: return "per day"
        default: return ""
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

#Preview("Ready") {
    PlatterProPaywallView(forcedContent: .ready([
        PlanCardData(id: "y", name: "Yearly", price: "$39.99", periodLabel: "per year"),
        PlanCardData(id: "m", name: "Monthly", price: "$4.99", periodLabel: "per month"),
    ]))
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
