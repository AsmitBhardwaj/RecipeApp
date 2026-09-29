//
//  BudgetPlanResultsView.swift
//  RecipeApp
//
//  "Your week": the Plan on a Budget results screen — budget card, a list of
//  dinner cards (no day labels), a sticky Grocery list / Use this plan bar, and
//  the per-dinner bottom sheet with swap + Cook Mode. Handles any dinner count
//  from 1 to 7.
//

import SwiftUI
import RecipeKit

// MARK: - Palette / shared bits

/// Tints from the plan design spec, layered on the app's own sage accent.
extension Color {
    static let planSelectedTint = Color(hex: "EEF3EC")
}

/// Asset image with a graceful fallback: when the named asset isn't in the
/// catalog yet (art drops in later), a soft tinted rounded square is shown, so
/// no code change is needed when the art lands.
struct SoftAssetImage: View {
    let name: String
    var size: CGFloat
    var cornerRadius: CGFloat = 14

    var body: some View {
        Group {
            if UIImage(named: name) != nil {
                Image(name).resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.planSelectedTint)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The food sticker for a meal name (keyword mapper in RecipeKit).
struct FoodStickerView: View {
    let mealName: String
    var size: CGFloat = 56

    var body: some View {
        SoftAssetImage(name: FoodSticker.category(forMealName: mealName).assetName, size: size)
    }
}

// MARK: - Action buttons

/// The one button system for this flow: 52pt tall, 16pt continuous corners, 17pt
/// semibold (scales with Dynamic Type), single-line label, press feedback (scale
/// 0.97 + slight fade) and a light haptic on tap.
struct PlanActionButton: View {
    enum Style { case filled, outlined, tinted }

    let title: String
    var icon: String?
    var style: Style = .filled
    /// Inline spinner in place of the icon; the caller passes the loading title.
    var isLoading = false
    var accessibilityLabel: String?
    var accessibilityHint: String?
    let action: () -> Void

    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 17

    private var foreground: Color { style == .filled ? .white : .accentColor }
    private let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView().tint(foreground)
                } else if let icon {
                    Image(systemName: icon).accessibilityHidden(true)
                }
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            }
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background {
                switch style {
                case .filled: shape.fill(Color.accentColor)
                case .tinted: shape.fill(Color.planSelectedTint)
                case .outlined:
                    shape.fill(Color.surface)
                    shape.strokeBorder(Color.accentColor, lineWidth: 1.5)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(PlanPressStyle())
        .accessibilityLabel(accessibilityLabel ?? title)
        .accessibilityHint(accessibilityHint ?? "")
    }
}

private struct PlanPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Two side-by-side children split `leadingShare` / rest with a fixed gap. When
/// asked for its ideal size it reports the width both labels need, so wrapping it
/// in `ViewThatFits` falls back to a vertical stack at large text sizes.
private struct SplitRow: Layout {
    var leadingShare: CGFloat = 0.6
    var spacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        if let width = proposal.width { return CGSize(width: width, height: height) }
        let a = subviews[0].sizeThatFits(.unspecified).width
        let b = subviews[1].sizeThatFits(.unspecified).width
        // Labels may shrink to 0.9 (minimumScaleFactor) before we give up and stack.
        let usable = max(a * 0.92 / leadingShare, b * 0.92 / (1 - leadingShare))
        return CGSize(width: usable + spacing, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let usable = bounds.width - spacing
        let w0 = usable * leadingShare
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: w0, height: bounds.height))
        subviews[1].place(at: CGPoint(x: bounds.minX + w0 + spacing, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: usable - w0, height: bounds.height))
    }
}

/// A soft highlight sweeping across a card (Reduce Motion: a static tint).
private struct Shimmer: ViewModifier {
    let active: Bool
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay {
            if active {
                GeometryReader { geo in
                    if reduceMotion {
                        Color.accentColor.opacity(0.06)
                    } else {
                        LinearGradient(
                            colors: [.clear, Color.accentColor.opacity(0.14), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: geo.size.width * 0.6)
                        .offset(x: phase * geo.size.width)
                        .onAppear {
                            phase = -0.6
                            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = 1.0 }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - Results

struct BudgetResultsView: View {
    @ObservedObject var model: BudgetPlanModel
    var userScope: String?
    var onOpenMealPlan: () -> Void
    @EnvironmentObject private var subscriptions: SubscriptionService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The reveal: the budget card fades/scales in, then the dinner cards stagger
    /// in ~60ms apart. Only plays for a freshly generated plan; a restored plan
    /// (or Reduce Motion) shows everything at once.
    @State private var budgetShown: Bool
    @State private var shownCards: Int

    init(model: BudgetPlanModel, userScope: String?, onOpenMealPlan: @escaping () -> Void) {
        self.model = model
        self.userScope = userScope
        self.onOpenMealPlan = onOpenMealPlan
        let fresh = model.isFreshReveal
        _budgetShown = State(initialValue: !fresh)
        _shownCards = State(initialValue: fresh ? 0 : .max)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BudgetSummaryCard(
                    total: model.total, budget: model.budgetValue, dinners: model.dinnerCount
                )
                .opacity(budgetShown ? 1 : 0)
                .scaleEffect(budgetShown ? 1 : 0.96)
                if let failure = model.swapFailure {
                    SwapFailureBanner(message: failure.message, isRetrying: model.isSwapping) {
                        Task { await model.retrySwap() }
                    }
                }
                VStack(spacing: 12) {
                    ForEach(Array(model.recipes.enumerated()), id: \.element.id) { index, planned in
                        DinnerCard(planned: planned, isSwapping: model.swappingIndex == index) {
                            model.selectedMealIndex = index
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                        .opacity(index < shownCards ? 1 : 0)
                        .offset(y: index < shownCards ? 0 : 14)
                    }
                }
                PlanReminderCard()
                    .opacity(shownCards >= model.dinnerCount ? 1 : 0)
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .padding(.bottom, 32)   // last card scrolls fully clear of the bar
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        #if DEBUG
        .defaultScrollAnchor(ProcessInfo.processInfo.arguments.contains("-debugScrollBottom") ? .bottom : .top)
        #endif
        // The header (title, New plan, free pill) is pinned above the scroll view so
        // it's always on screen — on first appear and while scrolling.
        .safeAreaInset(edge: .top, spacing: 0) { pinnedHeader }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .overlay(alignment: .top) {
            if model.showFreeSavedToast {
                Text("Your free week is saved to your recipes")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.textPrimary.opacity(0.92), in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityAddTraits(.isStaticText)
                    .onAppear { UIAccessibility.post(notification: .announcement, argument: "Your free week is saved to your recipes") }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: model.showFreeSavedToast)
        .onAppear { model.refreshAddedState() }
        .task { await playReveal() }
        .sheet(isPresented: $model.showGrocery) {
            BudgetGroceryListView(
                recipes: model.recipes.map(\.recipe),
                pantryNames: model.groceryPantryNames
            )
        }
        .sheet(isPresented: Binding(
            get: { model.selectedMealIndex != nil },
            set: { if !$0 { model.selectedMealIndex = nil } }
        )) {
            DinnerSheet(model: model, userScope: userScope)
                .environmentObject(subscriptions)
        }
    }

    // MARK: Reveal

    private func playReveal() async {
        if model.consumeFreshReveal() {
            if reduceMotion {
                budgetShown = true
                shownCards = .max
            } else {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) { budgetShown = true }
                try? await Task.sleep(nanoseconds: 300_000_000)
                for i in 1...max(model.dinnerCount, 1) {
                    guard !Task.isCancelled else { return }
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { shownCards = i }
                    try? await Task.sleep(nanoseconds: 60_000_000)
                }
                try? await Task.sleep(nanoseconds: 450_000_000)   // let the last card settle
                shownCards = .max
            }
        } else {
            budgetShown = true
            shownCards = .max
        }
        // After the cards are in: the free plan's one-time teaser, if it's due.
        await model.presentRevealTeaserIfDue()
    }

    // MARK: Header

    private var pinnedHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let swaps = model.swapsRemaining { freePlanPill(swaps) }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appBackground)
        .overlay(alignment: .bottom) { Color.hairline.frame(height: 1) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your week")
                    .font(.editorialTitle(size: 32, relativeTo: .largeTitle))
                    .foregroundStyle(Color.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button { model.newPlan() } label: {
                    Label("New plan", systemImage: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .background(Color.planSelectedTint, in: Capsule())
                        // Day-6 reminder tap (Pro): a brief sage ring draws the eye here.
                        .overlay(Capsule().strokeBorder(Color.accentColor, lineWidth: 2)
                            .opacity(model.highlightNewPlan ? 1 : 0))
                        .scaleEffect(model.highlightNewPlan ? 1.06 : 1)
                        .animation(.easeInOut(duration: 0.35), value: model.highlightNewPlan)
                        .frame(minHeight: 44)          // keep a 44pt tap target
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlanPressStyle())
                .accessibilityLabel("New plan")
                .accessibilityHint(model.swapsRemaining != nil ? "Shows Platter Pro" : "Starts a new plan")
            }
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "Estimated for <store name> shoppers · <N> people" (the store from the quiz;
    /// "Other" has no name to show, so it reads "your area").
    private var subtitle: String {
        let people = model.householdSize == 1 ? "1 person" : "\(model.householdSize) people"
        let who = model.regionLabel.map { "\($0) shoppers" } ?? "your area"
        return "Estimated for \(who) · \(people)"
    }

    private func freePlanPill(_ swaps: Int) -> some View {
        Text("Free plan · \(swaps) \(swaps == 1 ? "swap" : "swaps") left")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(Color.planSelectedTint, in: Capsule())
            .contentTransition(.numericText())
            .animation(.easeInOut(duration: 0.3), value: swaps)
            .accessibilityLabel("Free plan, \(swaps) \(swaps == 1 ? "swap" : "swaps") left")
    }

    // MARK: Sticky bar

    private var bottomBar: some View {
        let added = model.weekAdded
        let grocery = PlanActionButton(
            title: "Grocery list", icon: "cart", style: .outlined,
            accessibilityHint: "Shows the ingredients to buy for this plan"
        ) { model.showGrocery = true }
        let primary = PlanActionButton(
            title: added ? "Added ✓" : "Add to Meal Plan",
            icon: added ? nil : "calendar.badge.plus",
            style: added ? .tinted : .filled,
            accessibilityLabel: added ? "Added to Meal Plan" : "Add to Meal Plan",
            accessibilityHint: added ? "Opens your Meal Plan" : "Adds these dinners to open days in your Meal Plan"
        ) {
            if added { onOpenMealPlan() } else { model.addWeekToMealPlan() }
        }
        return ViewThatFits(in: .horizontal) {
            // ~60% primary / ~40% secondary, 12pt gap.
            SplitRow(leadingShare: 0.6, spacing: 12) { primary; grocery }
            // Large text: stack instead of truncating.
            VStack(spacing: 10) { primary; grocery }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Color.appBackground)
        .overlay(alignment: .top) {
            // Hairline divider, with a soft white fade above it so cards scrolling
            // under the bar don't cut off harshly.
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color.appBackground.opacity(0), Color.appBackground],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 24)
                    .offset(y: -24)
                    .allowsHitTesting(false)
                Rectangle().fill(Color.hairline).frame(height: 1)
            }
        }
    }
}

// MARK: - Budget card

private struct BudgetSummaryCard: View {
    let total: Double
    let budget: Double
    let dinners: Int

    private var totalInt: Int { Int(total.rounded()) }
    private var budgetInt: Int { max(Int(budget.rounded()), 0) }
    private var fraction: Double { min(1, max(0, total / max(budget, 1))) }
    private var leftText: String {
        let left = budgetInt - totalInt
        return left >= 0 ? "$\(left) left" : "$\(-left) over"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("$\(totalInt) of $\(budgetInt)")
                    .font(.system(size: 22, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: total))
                Spacer(minLength: 8)
                Text(dinners == 1 ? "1 dinner" : "\(dinners) dinners")
                    .font(.system(size: 14, weight: .medium))
                    .opacity(0.9)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.28))
                    Capsule().fill(Color.white).frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 8)
            Text("\(leftText) · tap any dinner to swap it")
                .font(.system(size: 13))
                .opacity(0.9)
        }
        .foregroundStyle(Color.white)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .animation(.easeInOut(duration: 0.45), value: total)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(totalInt) dollars of \(budgetInt) dollars budget, \(dinners) \(dinners == 1 ? "dinner" : "dinners"), \(leftText). Tap any dinner to swap it.")
    }
}

// MARK: - Dinner card

private struct DinnerCard: View {
    let planned: PlannedRecipe
    let isSwapping: Bool
    let onTap: () -> Void

    private var category: FoodSticker { FoodSticker.category(forMealName: planned.recipe.title) }

    private var accessibilitySummary: String {
        let equipment = DinnerEquipment.icons(for: planned.equipmentUsed).map(\.label)
        let parts = [planned.recipe.title, planned.costLabel, planned.timeLabel] + equipment
        return parts.compactMap { $0 }.joined(separator: ", ")
    }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 14) {
                DinnerTile(category: category, photoURL: planned.photoURL)
                VStack(alignment: .leading, spacing: 8) {
                    Text(planned.recipe.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    DinnerMetaRow(timeLabel: planned.timeLabel, equipment: planned.equipmentUsed)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                DinnerPricePill(text: planned.costLabel)
                    .accessibilityHidden(true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .dinnerCardSurface()
            .modifier(Shimmer(active: isSwapping))
            .opacity(isSwapping ? 0.8 : 1)
            .contentShape(RoundedRectangle(cornerRadius: DinnerCardSurface.radius, style: .continuous))
        }
        .buttonStyle(DinnerPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isSwapping ? "Swapping \(planned.recipe.title)" : accessibilitySummary)
        .accessibilityHint("Opens details and swap")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Swap failure

private struct SwapFailureBanner: View {
    let message: String
    let isRetrying: Bool
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: onRetry) {
                Text("Try again")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(isRetrying)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Dinner sheet

private struct DinnerSheet: View {
    @ObservedObject var model: BudgetPlanModel
    var userScope: String?
    @EnvironmentObject private var subscriptions: SubscriptionService
    @Environment(\.cookTimerScheduler) private var cookTimerScheduler
    @State private var cooking = false

    private var planned: PlannedRecipe? {
        guard let i = model.selectedMealIndex, model.recipes.indices.contains(i) else { return nil }
        return model.recipes[i]
    }

    var body: some View {
        Group {
            if let planned, let index = model.selectedMealIndex {
                content(planned, index: index)
            } else {
                Color.clear
            }
        }
        .background(Color.appBackground)
        .presentationDragIndicator(.visible)
        .onAppear { model.refreshAddedState() }
        // Teaser from inside the sheet (the root can't present over it).
        .fullScreenCover(isPresented: Binding(
            get: { model.showTeaser && model.selectedMealIndex != nil },
            set: { if !$0 { model.teaserClosed(isPro: subscriptions.isProUnlocked) } }
        )) {
            PaywallTeaserView(budget: Int(model.budgetValue.rounded()), dinners: model.dinnerCount, photoURLs: model.recipes.compactMap(\.photoURL)) { model.teaserClosed(isPro: $0) }
                .environmentObject(subscriptions)
        }
        .fullScreenCover(isPresented: $cooking) {
            if let planned {
                CookModeView(recipe: planned.recipe, userScope: userScope, scheduler: cookTimerScheduler)
            }
        }
    }

    /// Full-bleed 16:9 photo with rounded bottom corners and a Pexels credit.
    private func heroPhoto(_ url: String, credit: PhotoCredit?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay { PlanPhoto(url: url) { Color.textSecondary.opacity(0.08) } }
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 20, bottomTrailingRadius: 20, style: .continuous))
                .accessibilityHidden(true)
            if let credit, credit.photographer != nil || credit.pexelsUrl != nil {
                photoCaption(credit)
            }
        }
        // Bleed past the content's 24pt side padding to the sheet edges.
        .padding(.horizontal, -24)
    }

    private func photoCaption(_ credit: PhotoCredit) -> some View {
        let text = "Photo: \(credit.photographer ?? "Unknown") / Pexels"
        return Group {
            if let link = credit.pexelsUrl.flatMap(URL.init(string:)) {
                Link(text, destination: link)
            } else {
                Text(text)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Color.textSecondary)
        .padding(.horizontal, 24)
    }

    private func content(_ planned: PlannedRecipe, index: Int) -> some View {
        let recipe = planned.recipe
        let swapping = model.swappingIndex == index
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let photo = planned.photoURL, !photo.isEmpty {
                    heroPhoto(photo, credit: planned.photoCredit)
                }
                HStack(alignment: .center, spacing: 14) {
                    FoodStickerView(mealName: recipe.title, size: 72)
                    Text(recipe.title)
                        .font(.editorialTitle(size: 26, relativeTo: .title))
                        .foregroundStyle(Color.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }

                chips(planned)

                if !recipe.ingredients.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ingredients")
                            .font(.system(size: 16, weight: .semibold))
                            .accessibilityAddTraits(.isHeader)
                        ForEach(Array(recipe.ingredients.enumerated()), id: \.offset) { _, ingredient in
                            ingredientRow(ingredient)
                        }
                    }
                }

                if !recipe.instructions.isEmpty {
                    Text("\(recipe.instructions.count) \(recipe.instructions.count == 1 ? "step" : "steps") · opens in Cook Mode")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.textSecondary)
                }

                if let failure = model.swapFailure, failure.mealIndex == index {
                    SwapFailureBanner(message: failure.message, isRetrying: swapping) {
                        Task { await model.retrySwap() }
                    }
                }

                actions(planned, index: index, swapping: swapping)

                if let swaps = model.swapsRemaining {
                    Text("\(swaps) free \(swaps == 1 ? "swap" : "swaps") left · keeps you within $\(Int(model.budgetValue.rounded()))")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.textSecondary)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.3), value: swaps)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, planned.photoURL?.isEmpty == false ? 0 : 28)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Pieces

    private func chips(_ planned: PlannedRecipe) -> some View {
        let servings = planned.recipe.servings.amount.map { Int($0.rounded()) } ?? model.householdSize
        var items: [(String, String)] = [("dollarsign.circle", planned.costLabel)]
        if let time = planned.timeLabel { items.append(("clock", time)) }
        items.append(("person.2", "Serves \(servings)"))
        if !planned.equipmentSummary.isEmpty { items.append(("frying.pan", planned.equipmentSummary)) }
        return FlowChips(items: items)
    }

    private func ingredientRow(_ ingredient: Ingredient) -> some View {
        let parts = IngredientTextFormatter.parts(for: ingredient)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(Color.accentColor.opacity(0.5)).frame(width: 5, height: 5)
                .accessibilityHidden(true)
            (Text(parts.measurement ?? "").fontWeight(.semibold) + Text(parts.remainder))
                .font(.system(size: 15))
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func actions(_ planned: PlannedRecipe, index: Int, swapping: Bool) -> some View {
        let added = model.isAdded(planned.id)
        return VStack(spacing: 10) {
            PlanActionButton(
                title: swapping ? "Finding a swap…" : "Swap this dinner",
                icon: "arrow.triangle.2.circlepath", style: .outlined, isLoading: swapping,
                accessibilityLabel: swapping ? "Finding a swap" : "Swap this dinner"
            ) { Task { await model.swapMeal(at: index) } }
            .disabled(model.isSwapping)

            PlanActionButton(
                title: added ? "Added ✓" : "Add to Meal Plan",
                icon: added ? nil : "calendar.badge.plus", style: added ? .tinted : .outlined,
                accessibilityLabel: added ? "Added to Meal Plan" : "Add to Meal Plan"
            ) { model.addDinnerToMealPlan(at: index) }
            .disabled(added || swapping)

            // Primary action last.
            if !planned.recipe.instructions.isEmpty {
                PlanActionButton(
                    title: "Start cooking", icon: "flame", style: .filled,
                    accessibilityLabel: "Start cooking \(planned.recipe.title)"
                ) { cooking = true }
                .disabled(swapping)
            }
        }
    }
}

/// Wrapping row of icon + text chips.
private struct FlowChips: View {
    let items: [(icon: String, text: String)]

    var body: some View {
        ChipFlowLayout(spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 6) {
                    Image(systemName: item.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .accessibilityHidden(true)
                    Text(item.text)
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(Color.textPrimary)
                .padding(.horizontal, 12)
                .frame(minHeight: 34)
                .background(Color.planSelectedTint, in: Capsule())
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (i, origin) in result.origins.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}
