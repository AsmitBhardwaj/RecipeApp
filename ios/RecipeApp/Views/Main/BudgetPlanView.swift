//
//  BudgetPlanView.swift
//  RecipeApp
//
//  "Plan on a Budget" — a mode inside the Meal Plan tab (docs/budget-meal-planning.md).
//  Setup → Generating → Results ("Your week", see BudgetPlanResultsView.swift).
//  The server decides who may generate (a free account gets one plan; Pro is
//  unlimited), so there is no client-side Pro lock: a 403 pro_required opens the
//  paywall. Budget math (per-person minimum, raise-only) mirrors the server via
//  RecipeKit.BudgetMath.
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

    /// A failed swap, kept so the UI can show the message and a retry action.
    struct SwapFailure: Equatable {
        let mealIndex: Int
        let message: String
    }

    typealias Generate = (_ budget: Int, _ household: Int, _ dietary: [String], _ pantry: [String], _ options: BudgetPlanOptions) async throws -> BudgetPlanResponse
    typealias Swap = (_ planID: String, _ mealIndex: Int) async throws -> BudgetSwapResponse

    @Published var phase: Phase = .setup
    @Published private(set) var budget: Int
    @Published private(set) var householdSize: Int
    @Published var useKitchen: Bool = true
    @Published private(set) var recipes: [PlannedRecipe] = []
    @Published private(set) var response: BudgetPlanResponse?
    @Published var showPaywall = false
    @Published private(set) var budgetInputMessage: String?

    // Results state
    @Published private(set) var planID: String?
    /// Current plan total; comes from the server after a swap, summed locally only
    /// for the initial response.
    @Published private(set) var total: Double = 0
    /// Server-supplied; nil = unlimited (Pro) → no pill. Never counted client-side.
    @Published private(set) var swapsRemaining: Int?
    @Published private(set) var swappingIndex: Int?
    @Published var swapFailure: SwapFailure?
    /// The dinner whose sheet is open.
    @Published var selectedMealIndex: Int?
    @Published var showGrocery = false

    /// Shown in "Estimated for <label> shoppers" until Stage 2 supplies a store.
    let regionLabel: String?

    private let dietaryPreferences: [DietaryPreference]
    private let pantryNames: () -> [String]
    private let options: () -> BudgetPlanOptions
    private let generate: Generate
    private let swap: Swap
    private let commit: (_ recipes: [PlannedRecipe]) -> Void

    private let budgetStep = 5

    init(
        budget: Int = 75,
        householdSize: Int,
        dietaryPreferences: [DietaryPreference],
        regionLabel: String? = nil,
        pantryNames: @escaping () -> [String],
        options: @escaping () -> BudgetPlanOptions = { .none },
        generate: @escaping Generate,
        swap: @escaping Swap,
        commit: @escaping (_ recipes: [PlannedRecipe]) -> Void
    ) {
        let hs = max(1, min(householdSize, 12))
        self.householdSize = hs
        self.dietaryPreferences = dietaryPreferences
        self.regionLabel = regionLabel
        self.pantryNames = pantryNames
        self.options = options
        self.generate = generate
        self.swap = swap
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
            let resp = try await generate(budget, householdSize, dietary, pantry, options())
            guard !resp.recipes.isEmpty else {
                phase = .failed("We couldn't build a plan this time. Please try again.")
                return
            }
            apply(resp)
            phase = .results
        } catch BudgetPlanError.proRequired, BudgetPlanError.freePlanUsed {
            // The server decides who may generate; both mean "show the paywall".
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

    private func apply(_ resp: BudgetPlanResponse) {
        response = resp
        recipes = resp.recipes
        planID = resp.planId
        total = resp.total
        swapsRemaining = resp.swapsRemaining
        swappingIndex = nil
        swapFailure = nil
        selectedMealIndex = nil
    }

    // MARK: Derived (results)

    var budgetValue: Double { response?.budget ?? Double(budget) }
    var dinnerCount: Int { recipes.count }
    var amountLeft: Double { budgetValue - total }
    var isSwapping: Bool { swappingIndex != nil }

    // MARK: Swap

    /// Replace the dinner at `index` in place. Errors never leave the screen
    /// blank: they land in `swapFailure` (message + retry), except the paywall
    /// cases, which open the existing paywall.
    func swapMeal(at index: Int) async {
        guard recipes.indices.contains(index), swappingIndex == nil else { return }
        guard let planID else {
            swapFailure = SwapFailure(mealIndex: index, message: "This plan can't be swapped. Try building a new one.")
            return
        }
        swappingIndex = index
        swapFailure = nil
        defer { swappingIndex = nil }
        do {
            let result = try await swap(planID, index)
            guard recipes.indices.contains(result.mealIndex) else { return }
            withAnimation(.easeInOut(duration: 0.35)) {
                recipes[result.mealIndex] = result.meal
                total = result.planTotal
                swapsRemaining = result.swapsRemaining
            }
        } catch BudgetPlanError.freeSwapsUsed {
            swapsRemaining = 0
            showPaywall = true
        } catch BudgetPlanError.proRequired, BudgetPlanError.freePlanUsed {
            showPaywall = true
        } catch let error as BudgetPlanError {
            swapFailure = SwapFailure(mealIndex: index, message: error.swapMessage)
        } catch {
            swapFailure = SwapFailure(mealIndex: index, message: "Couldn't swap this dinner. Please try again.")
        }
    }

    func retrySwap() async {
        guard let failure = swapFailure else { return }
        await swapMeal(at: failure.mealIndex)
    }

    // MARK: Grocery / commit

    var groceryPantryNames: [String] { pantryNames() }

    /// "Use this plan": commits every dinner (there are no per-dinner toggles now).
    func usePlan() { commit(recipes) }
    func startOver() { phase = .setup }
}

private extension BudgetPlanError {
    /// Message for a failed swap (differs from generation wording).
    var swapMessage: String {
        switch self {
        case .constraintUnmet: return "Couldn't find a swap that fits — try again."
        case .planChanged: return "This plan just changed. Please try again."
        case .offline, .timedOut, .spendCapReached: return userMessage
        default: return "Couldn't swap this dinner. Please try again."
        }
    }
}

// MARK: - Container

/// Owns the `BudgetPlanModel` as a `@StateObject`, built from dependencies that
/// are only available in the parent's `body` (environment + sibling models), which
/// a `@StateObject` in the parent can't capture at init.
struct BudgetPlanContainer: View {
    @StateObject private var model: BudgetPlanModel
    private let onSaved: () -> Void
    private let userScope: String?
    /// DEBUG/QA only: auto-run generation on appear so the results state can be
    /// screenshotted. Always false in production.
    private let autoGenerate: Bool
    @State private var didAutoGenerate = false

    init(
        householdSize: Int,
        dietary: [DietaryPreference],
        regionLabel: String? = nil,
        userScope: String? = nil,
        pantryNames: @escaping () -> [String],
        options: @escaping () -> BudgetPlanOptions = { .none },
        generate: @escaping BudgetPlanModel.Generate,
        swap: @escaping BudgetPlanModel.Swap,
        commit: @escaping (_ recipes: [PlannedRecipe]) -> Void,
        onSaved: @escaping () -> Void,
        autoGenerate: Bool = false
    ) {
        _model = StateObject(wrappedValue: BudgetPlanModel(
            householdSize: householdSize,
            dietaryPreferences: dietary,
            regionLabel: regionLabel,
            pantryNames: pantryNames,
            options: options,
            generate: generate,
            swap: swap,
            commit: commit
        ))
        self.onSaved = onSaved
        self.userScope = userScope
        self.autoGenerate = autoGenerate
    }

    var body: some View {
        BudgetPlanView(model: model, userScope: userScope, onSaved: onSaved)
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
    var userScope: String? = nil
    /// Called after "Use this plan" so the tab returns to "This Week".
    var onSaved: () -> Void = {}

    var body: some View {
        Group {
            switch model.phase {
            case .setup: BudgetSetupView(model: model)
            case .generating: BudgetGeneratingView()
            case .results: BudgetResultsView(model: model, userScope: userScope, onSaved: onSaved)
            case .failed(let message): failedState(message)
            }
        }
        // The paywall hangs off the meal sheet when it's open (a sheet can't be
        // presented over a presenting view that already has one), else off the root.
        .sheet(isPresented: Binding(
            get: { model.showPaywall && model.selectedMealIndex == nil },
            set: { if !$0 { model.showPaywall = false } }
        )) {
            PlatterProPaywallView().environmentObject(subscriptions)
        }
    }

    private func failedState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
            Button("Try Again") { Task { await model.generatePlan() } }
                .font(.headline)
                .foregroundStyle(Color.accentColor)
                .frame(minHeight: 44)
            Button("Change budget") { model.startOver() }
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)
                .frame(minHeight: 44)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
