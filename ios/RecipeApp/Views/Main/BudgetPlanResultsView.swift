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
private extension Color {
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

// MARK: - Results

struct BudgetResultsView: View {
    @ObservedObject var model: BudgetPlanModel
    var userScope: String?
    var onSaved: () -> Void
    @EnvironmentObject private var subscriptions: SubscriptionService

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let swaps = model.swapsRemaining { freePlanPill(swaps) }
                BudgetSummaryCard(
                    total: model.total, budget: model.budgetValue, dinners: model.dinnerCount
                )
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
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
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

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Your week")
                .font(.editorialTitle(size: 32, relativeTo: .largeTitle))
                .foregroundStyle(Color.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "Estimated for <store name> shoppers · <N> people". Until the store
    /// picker exists (Stage 2) this uses the region label.
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
        HStack(spacing: 12) {
            Button { model.showGrocery = true } label: {
                Text("Grocery list")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Grocery list")
            .accessibilityHint("Shows the ingredients to buy for this plan")

            Button {
                model.usePlan()
                onSaved()
            } label: {
                Text("Use this plan")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Use this plan")
            .accessibilityHint("Adds these dinners to your meal plan")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Color.appBackground)
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

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                FoodStickerView(mealName: planned.recipe.title, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(planned.recipe.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(planned.cardDetail)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if isSwapping {
                    ProgressView().tint(Color.accentColor)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.textSecondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.hairline, lineWidth: 1)
            }
            .opacity(isSwapping ? 0.55 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSwapping ? "Swapping \(planned.recipe.title)" : "\(planned.recipe.title), \(planned.cardDetail)")
        .accessibilityHint("Opens details and swap")
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
        // Paywall from inside the sheet (the root can't present over it).
        .sheet(isPresented: Binding(
            get: { model.showPaywall && model.selectedMealIndex != nil },
            set: { if !$0 { model.showPaywall = false } }
        )) {
            PlatterProPaywallView().environmentObject(subscriptions)
        }
        .fullScreenCover(isPresented: $cooking) {
            if let planned {
                CookModeView(recipe: planned.recipe, userScope: userScope, scheduler: cookTimerScheduler)
            }
        }
    }

    private func content(_ planned: PlannedRecipe, index: Int) -> some View {
        let recipe = planned.recipe
        let swapping = model.swappingIndex == index
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
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
            .padding(.top, 28)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(swapping ? 0.6 : 1)
            .animation(.easeInOut(duration: 0.2), value: swapping)
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
        VStack(spacing: 12) {
            Button {
                Task { await model.swapMeal(at: index) }
            } label: {
                HStack(spacing: 8) {
                    if swapping {
                        ProgressView().tint(Color.accentColor)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .accessibilityHidden(true)
                    }
                    Text(swapping ? "Swapping…" : "Swap this dinner")
                }
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity, minHeight: 56)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                }
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(model.isSwapping)
            .accessibilityLabel(swapping ? "Swapping this dinner" : "Swap this dinner")

            if !planned.recipe.instructions.isEmpty {
                Button { cooking = true } label: {
                    Text("Start cooking")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(swapping)
                .accessibilityLabel("Start cooking \(planned.recipe.title)")
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
