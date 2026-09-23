//
//  BudgetPlanView.swift
//  RecipeApp
//
//  "Plan on a Budget" — a mode inside the Meal Plan tab (docs/budget-meal-planning.md).
//  Setup → Generating → Results, all Pro-gated. Free users see a locked state.
//  Budget math (per-person minimum, raise-only) mirrors the server via
//  RecipeKit.BudgetMath; generation is Pro-gated server-side too.
//

import SwiftUI
import RecipeKit

// MARK: - Model

@MainActor
final class BudgetPlanModel: ObservableObject {
    enum Phase: Equatable {
        case setup
        case generating
        case results
        case failed(String)
    }

    @Published var phase: Phase = .setup
    @Published private(set) var budget: Int
    @Published private(set) var householdSize: Int
    @Published var useKitchen: Bool = true
    @Published private(set) var recipes: [PlannedRecipe] = []
    @Published private(set) var response: BudgetPlanResponse?
    @Published var selection = BudgetPlanSelection(recipes: [])
    @Published var showPaywall = false
    @Published private(set) var budgetInputMessage: String?

    private let dietaryPreferences: [DietaryPreference]
    private let pantryNames: () -> [String]
    private let generate: (_ budget: Int, _ household: Int, _ dietary: [String], _ pantry: [String]) async throws -> BudgetPlanResponse
    private let commit: (_ recipes: [PlannedRecipe]) -> Void

    private let budgetStep = 5

    init(
        budget: Int = 75,
        householdSize: Int,
        dietaryPreferences: [DietaryPreference],
        pantryNames: @escaping () -> [String],
        generate: @escaping (_ budget: Int, _ household: Int, _ dietary: [String], _ pantry: [String]) async throws -> BudgetPlanResponse,
        commit: @escaping (_ recipes: [PlannedRecipe]) -> Void
    ) {
        let hs = max(1, min(householdSize, 12))
        self.householdSize = hs
        self.dietaryPreferences = dietaryPreferences
        self.pantryNames = pantryNames
        self.generate = generate
        self.commit = commit
        // Never start below the per-person minimum.
        self.budget = BudgetMath.reconciled(currentBudget: budget, householdSize: hs)
    }

    // Budget stepper (block 1 + 2).
    var minBudget: Int { BudgetMath.minBudget(householdSize: householdSize) }
    var maxBudget: Int { BudgetMath.maxBudget(householdSize: householdSize) }
    var minimumCaption: String { BudgetMath.minimumCaption(householdSize: householdSize) }
    var canDecrementBudget: Bool { budget > minBudget }
    var canIncrementBudget: Bool { budget < maxBudget }

    func incrementBudget() {
        guard canIncrementBudget else { return }
        budget = min(maxBudget, budget + budgetStep)
        budgetInputMessage = nil
    }

    func decrementBudget() {
        guard canDecrementBudget else { return }
        budget = max(minBudget, budget - budgetStep)
        budgetInputMessage = nil
    }

    /// Applies direct text entry to the same value the stepper mutates. Invalid,
    /// empty, or out-of-range text leaves the last valid budget untouched.
    @discardableResult
    func setBudget(from input: String) -> Bool {
        switch BudgetMath.validateInput(input, householdSize: householdSize) {
        case .valid(let amount):
            budget = amount
            budgetInputMessage = nil
            return true
        case .belowMinimum(let minimum):
            budgetInputMessage = BudgetPlanError.belowMinimum(minBudget: minimum).userMessage
        case .aboveMaximum(let maximum):
            budgetInputMessage = BudgetPlanError.aboveMaximum(maxBudget: maximum).userMessage
        case .notNumeric:
            budgetInputMessage = "Enter a numeric budget amount."
        case .empty:
            budgetInputMessage = nil
        }
        return false
    }

    /// Changing household size recomputes the minimum immediately and raises the
    /// budget to it if below — but never lowers a budget the user chose.
    func setHousehold(_ n: Int) {
        householdSize = max(1, min(n, 12))
        budget = BudgetMath.reconciled(currentBudget: budget, householdSize: householdSize)
        budgetInputMessage = nil
    }

    func generatePlan() async {
        phase = .generating
        let dietary = dietaryPreferences.filter { $0 != .noRestrictions }.map(\.displayName)
        let pantry = useKitchen ? pantryNames() : []
        do {
            let resp = try await generate(budget, householdSize, dietary, pantry)
            response = resp
            recipes = resp.recipes
            selection = BudgetPlanSelection(recipes: resp.recipes)
            phase = .results
        } catch BudgetPlanError.proRequired {
            showPaywall = true
            phase = .setup
        } catch BudgetPlanError.belowMinimum(let mn) {
            // Server floor caught something the client didn't; correct and let them retry.
            budget = max(budget, mn)
            phase = .setup
        } catch let error as BudgetPlanError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Something went wrong. Please try again.")
        }
    }

    func toggle(_ id: String) { selection.toggle(id) }
    func isAccepted(_ id: String) -> Bool { selection.isAccepted(id) }
    var acceptedCount: Int { selection.acceptedCount }
    var totalSpent: Double { selection.totalCost(from: recipes) }
    var budgetValue: Double { response?.budget ?? Double(budget) }

    /// Missing-ingredients preview: unique recipe ingredient names across accepted
    /// recipes, minus what's on hand (normalized). "Just what's missing" (v1: name
    /// match only, no unit conversion — mirrors GroceryAggregator's edges).
    func missingIngredients() -> [String] {
        let onHand = Set(pantryNames().map { $0.lowercased() })
        var seen = Set<String>()
        var out: [String] = []
        for planned in selection.accepted(from: recipes) {
            for ing in planned.recipe.ingredients {
                let key = ing.name.lowercased()
                if key.isEmpty || onHand.contains(key) || seen.contains(key) { continue }
                seen.insert(key)
                out.append(ing.name)
            }
        }
        return out
    }

    func save() { commit(selection.accepted(from: recipes)) }
    func startOver() { phase = .setup }
}

// MARK: - Container

/// Owns the `BudgetPlanModel` as a `@StateObject`, built from dependencies that
/// are only available in the parent's `body` (environment + sibling models), which
/// a `@StateObject` in the parent can't capture at init.
struct BudgetPlanContainer: View {
    @StateObject private var model: BudgetPlanModel
    private let onSaved: () -> Void
    /// DEBUG/QA only: auto-run generation on appear so the results state can be
    /// screenshotted. Always false in production.
    private let autoGenerate: Bool
    @State private var didAutoGenerate = false

    init(
        householdSize: Int,
        dietary: [DietaryPreference],
        pantryNames: @escaping () -> [String],
        generate: @escaping (_ budget: Int, _ household: Int, _ dietary: [String], _ pantry: [String]) async throws -> BudgetPlanResponse,
        commit: @escaping (_ recipes: [PlannedRecipe]) -> Void,
        onSaved: @escaping () -> Void,
        autoGenerate: Bool = false
    ) {
        _model = StateObject(wrappedValue: BudgetPlanModel(
            householdSize: householdSize,
            dietaryPreferences: dietary,
            pantryNames: pantryNames,
            generate: generate,
            commit: commit
        ))
        self.onSaved = onSaved
        self.autoGenerate = autoGenerate
    }

    var body: some View {
        BudgetPlanView(model: model, onSaved: onSaved)
            .task {
                if autoGenerate && !didAutoGenerate {
                    didAutoGenerate = true
                    await model.generatePlan()
                }
            }
    }
}

// MARK: - Root

struct BudgetPlanView: View {
    @ObservedObject var model: BudgetPlanModel
    @EnvironmentObject private var subscriptions: SubscriptionService
    /// Called after Save to Meal Plan so the tab returns to "This Week".
    var onSaved: () -> Void = {}

    var body: some View {
        Group {
            if !subscriptions.isProUnlocked {
                lockedState
            } else {
                switch model.phase {
                case .setup: BudgetSetupView(model: model)
                case .generating: BudgetGeneratingView()
                case .results: BudgetResultsView(model: model, onSaved: onSaved)
                case .failed(let message): failedState(message)
                }
            }
        }
        .sheet(isPresented: $model.showPaywall) {
            PlatterProPaywallView().environmentObject(subscriptions)
        }
    }

    private var lockedState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                budgetHeadline
                ProSuggestionsLockedCardBudget(onUpgrade: { model.showPaywall = true })
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, Theme.Spacing.tabBarClearance)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func failedState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
            Button("Try Again") { Task { await model.generatePlan() } }
                .font(.headline)
                .foregroundStyle(Color.accentColor)
                .frame(minHeight: 44)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var budgetHeadline: some View {
        VStack(alignment: .leading, spacing: -4) {
            Text("Plan on a")
                .font(.editorialTitle(size: 32, relativeTo: .largeTitle))
            Text("budget.")
                .font(.scriptAccent(size: 38, relativeTo: .largeTitle))
                .foregroundStyle(Color.accentColor)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Plan on a budget")
    }
}

/// Locked card for the budget mode (mirrors ProSuggestionsLockedCard copy).
private struct ProSuggestionsLockedCardBudget: View {
    let onUpgrade: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 40)
                    .background(Color.sageLight.opacity(0.42), in: Circle())
                    .accessibilityHidden(true)
                Text("Plan a week of meals that fits your budget with Platter Pro.")
                    .font(.subheadline)
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: onUpgrade) {
                Text("Try Platter Pro")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.hairline, lineWidth: 1) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Plan on a Budget is a Platter Pro feature")
        .accessibilityHint("Opens Platter Pro")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Setup

private struct BudgetSetupView: View {
    @ObservedObject var model: BudgetPlanModel
    @State private var budgetText: String
    @FocusState private var isBudgetFocused: Bool

    init(model: BudgetPlanModel) {
        self.model = model
        _budgetText = State(initialValue: String(model.budget))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: -4) {
                    Text("Plan on a")
                        .font(.editorialTitle(size: 32, relativeTo: .largeTitle))
                    Text("budget.")
                        .font(.scriptAccent(size: 38, relativeTo: .largeTitle))
                        .foregroundStyle(Color.accentColor)
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Plan on a budget")

                budgetField
                householdField
                kitchenToggle

                Button {
                    if commitBudgetText() {
                        Task { await model.generatePlan() }
                    }
                } label: {
                    Text("Generate Plan")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, Theme.Spacing.tabBarClearance)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var budgetField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Weekly budget")
                .font(.system(size: 16, weight: .semibold))
            HStack(spacing: 16) {
                stepperButton("minus", enabled: model.canDecrementBudget) { model.decrementBudget() }
                    .accessibilityLabel("Decrease budget")
                HStack(spacing: 1) {
                    Text("$")
                        .accessibilityHidden(true)
                    TextField("Budget", text: $budgetText)
                        .keyboardType(.decimalPad)
                        .focused($isBudgetFocused)
                        .multilineTextAlignment(.leading)
                        .frame(width: 70)
                        .onSubmit { commitBudgetText() }
                        .accessibilityLabel("Weekly budget")
                        .accessibilityValue("$\(model.budget)")
                }
                .font(.system(size: 28, weight: .bold))
                .monospacedDigit()
                .frame(minWidth: 90)
                stepperButton("plus", enabled: model.canIncrementBudget) { model.incrementBudget() }
                    .accessibilityLabel("Increase budget")
                Spacer()
            }
            Text(model.budgetInputMessage ?? model.minimumCaption)
                .font(.system(size: 13))
                .foregroundStyle(model.budgetInputMessage == nil ? Color.textSecondary : Color.orange)
                .accessibilityLabel(model.budgetInputMessage ?? model.minimumCaption)
        }
        .onChange(of: model.budget) { _, newValue in
            budgetText = String(newValue)
        }
        .onChange(of: isBudgetFocused) { _, focused in
            if !focused { commitBudgetText() }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { isBudgetFocused = false }
            }
        }
    }

    @discardableResult
    private func commitBudgetText() -> Bool {
        let accepted = model.setBudget(from: budgetText)
        budgetText = String(model.budget)
        return accepted
    }

    private var householdField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Household size")
                .font(.system(size: 16, weight: .semibold))
            HStack(spacing: 16) {
                stepperButton("minus", enabled: model.householdSize > 1) { model.setHousehold(model.householdSize - 1) }
                    .accessibilityLabel("Decrease household size")
                Text("\(model.householdSize)")
                    .font(.system(size: 28, weight: .bold))
                    .monospacedDigit()
                    .frame(minWidth: 90)
                    .accessibilityLabel("\(model.householdSize) people")
                stepperButton("plus", enabled: model.householdSize < 12) { model.setHousehold(model.householdSize + 1) }
                    .accessibilityLabel("Increase household size")
                Spacer()
            }
        }
    }

    private var kitchenToggle: some View {
        Toggle(isOn: $model.useKitchen) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Use what's in my Kitchen")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Text("Prefer recipes that use ingredients you already have.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(Color.accentColor)
        .accessibilityLabel("Use what's in my Kitchen")
    }

    private func stepperButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(enabled ? Color.white : Color.textSecondary)
                .frame(width: 44, height: 44)
                .background(enabled ? Color.accentColor : Color.hairline, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - Generating

private struct BudgetGeneratingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    ProgressView().tint(Color.accentColor)
                    Text("Building your plan…")
                        .font(.headline)
                }
                .padding(.bottom, 4)
                ForEach(0..<4, id: \.self) { _ in skeletonCard }
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, Theme.Spacing.tabBarClearance)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel("Building your plan")
    }

    private var skeletonCard: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.surface)
            .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.hairline, lineWidth: 1) }
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 10) {
                    Capsule().fill(Color.hairline).frame(width: 160, height: 14)
                    Capsule().fill(Color.hairline).frame(width: 90, height: 10)
                }
                .padding(16)
            }
            .frame(height: 84)
            .accessibilityHidden(true)
    }
}

// MARK: - Results

private struct BudgetResultsView: View {
    @ObservedObject var model: BudgetPlanModel
    var onSaved: () -> Void
    @State private var showGroceryPreview = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                budgetBar
                ForEach(model.recipes) { planned in
                    recipeCard(planned)
                }
                groceryPreviewRow
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, Theme.Spacing.tabBarClearance)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) { saveBar }
        .sheet(isPresented: $showGroceryPreview) { groceryPreviewSheet }
    }

    private var budgetBar: some View {
        let spent = model.totalSpent
        let budget = max(model.budgetValue, 1)
        let fraction = min(1.0, spent / budget)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("$\(Int(spent.rounded())) of $\(Int(budget.rounded()))")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Text("\(model.acceptedCount) of \(model.recipes.count) meals")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.textSecondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.hairline).frame(height: 8)
                    Capsule().fill(spent > budget ? Color.orange : Color.accentColor)
                        .frame(width: geo.size.width * fraction, height: 8)
                }
            }
            .frame(height: 8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("$\(Int(spent.rounded())) spent of $\(Int(budget.rounded())), \(model.acceptedCount) of \(model.recipes.count) meals added")
    }

    private func recipeCard(_ planned: PlannedRecipe) -> some View {
        let accepted = model.isAccepted(planned.id)
        return Button {
            model.toggle(planned.id)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(planned.recipe.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 8) {
                        Text("$\(Int(planned.estimatedCost.amount.rounded()))")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.textPrimary)
                        if !planned.healthSignal.isEmpty {
                            Text(planned.healthSignal)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.sageLight.opacity(0.42), in: Capsule())
                        }
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: accepted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(accepted ? Color.accentColor : Color.textSecondary.opacity(0.5))
                    .accessibilityHidden(true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(accepted ? Color.sageLight.opacity(0.42) : Color.surface,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(accepted ? Color.accentColor : Color.hairline, lineWidth: accepted ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(planned.recipe.title), $\(Int(planned.estimatedCost.amount.rounded())), \(planned.healthSignal)")
        .accessibilityValue(accepted ? "In your plan" : "Not in your plan")
        .accessibilityAddTraits(accepted ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Double-tap to toggle this meal in your plan")
    }

    private var groceryPreviewRow: some View {
        Button { showGroceryPreview = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "cart")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text("Grocery list")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                Spacer(minLength: 8)
                Text("\(model.missingIngredients().count) items")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.textSecondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.textSecondary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.hairline, lineWidth: 1) }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Grocery list, \(model.missingIngredients().count) items")
        .accessibilityHint("Preview what's missing for this plan")
    }

    private var saveBar: some View {
        VStack(spacing: 0) {
            Button {
                model.save()
                onSaved()
            } label: {
                Text("Save to Meal Plan")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(Color.accentColor.opacity(model.acceptedCount > 0 ? 1 : 0.4),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(model.acceptedCount == 0)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .background(Color.creamTint)
    }

    private var groceryPreviewSheet: some View {
        let items = model.missingIngredients()
        return NavigationStack {
            List {
                if items.isEmpty {
                    Text("Nothing to buy — your Kitchen covers this plan.")
                        .foregroundStyle(Color.textSecondary)
                } else {
                    ForEach(items, id: \.self) { Text($0) }
                }
            }
            .navigationTitle("What's missing")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
