//
//  BudgetPlanView.swift
//  RecipeApp
//
//  "Plan on a Budget" — a mode inside the Meal Plan tab (docs/budget-meal-planning.md).
//  Setup → Generating → Results ("Your week", see BudgetPlanResultsView.swift).
//  Setup is the quiz's Mood → Appliances → Store → Budget screens (PlanQuizFlow),
//  presented full-screen; the answers live in CookingPreferences.
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

    /// The dinners already in the Meal Plan (derived from the plan itself, so it
    /// survives relaunch and reflects removals on the next refresh).
    @Published private(set) var addedIDs: Set<String> = []
    /// One-time "free week saved" toast, shown right after a free plan generates.
    @Published private(set) var showFreeSavedToast = false

    /// The store name in "Estimated for <store> shoppers" (nil for "Other").
    private(set) var regionLabel: String?

    private var dietaryPreferences: [DietaryPreference]
    /// Request options taken from the quiz answers (store tier, appliances, moods);
    /// when nil the injected `options` closure is used.
    private var optionsOverride: BudgetPlanOptions?
    private let pantryNames: () -> [String]
    private let options: () -> BudgetPlanOptions
    private let generate: Generate
    private let swap: Swap
    private let commit: (_ recipes: [PlannedRecipe]) -> Void
    private let addDinnerToMealPlan: (_ recipe: PlannedRecipe) -> Void
    private let isInMealPlan: (_ recipeId: String) -> Bool
    private let savedPlanStore: SavedBudgetPlanStore?
    private let onFreePlanGenerated: (_ recipes: [Recipe]) -> Void
    private let onMealSwapped: (_ old: Recipe, _ new: Recipe) -> Void
    private var toastTask: Task<Void, Never>?
    /// Set when "New plan" opened the paywall, so a purchase continues to setup.
    private var newPlanPending = false

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
        commit: @escaping (_ recipes: [PlannedRecipe]) -> Void,
        addDinner: @escaping (_ recipe: PlannedRecipe) -> Void = { _ in },
        isInMealPlan: @escaping (_ recipeId: String) -> Bool = { _ in false },
        savedPlanStore: SavedBudgetPlanStore? = nil,
        onFreePlanGenerated: @escaping (_ recipes: [Recipe]) -> Void = { _ in },
        onMealSwapped: @escaping (_ old: Recipe, _ new: Recipe) -> Void = { _, _ in }
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
        self.addDinnerToMealPlan = addDinner
        self.isInMealPlan = isInMealPlan
        self.savedPlanStore = savedPlanStore
        self.onFreePlanGenerated = onFreePlanGenerated
        self.onMealSwapped = onMealSwapped
        // Never start below the per-person minimum.
        self.budget = BudgetMath.reconciled(currentBudget: budget, householdSize: hs)
        restoreSavedPlan()
    }

    // MARK: Persistence

    /// Reopening Plan on a Budget shows the saved "Your week" instead of setup.
    private func restoreSavedPlan() {
        guard let saved = savedPlanStore?.load(), !saved.recipes.isEmpty else { return }
        householdSize = max(1, min(saved.householdSize, 12))
        regionLabel = saved.regionLabel
        apply(BudgetPlanResponse(
            recipes: saved.recipes, currency: saved.currency, budget: saved.budget, minBudget: 0,
            regionalMultiplier: 1, planId: saved.planId, isFree: saved.isFree, swapsRemaining: saved.swapsRemaining
        ))
        total = saved.total   // the saved total already reflects any swaps
        phase = .results
    }

    private func persist() {
        guard let response, !recipes.isEmpty else { return }
        savedPlanStore?.save(SavedBudgetPlan(
            planId: planID, recipes: recipes, total: total, budget: response.budget, currency: response.currency,
            swapsRemaining: swapsRemaining, isFree: response.isFree,
            householdSize: householdSize, regionLabel: regionLabel
        ))
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

    /// Generate from the quiz answers: household, diet, moods, appliances, store
    /// tier and budget. The answers are already saved; this only feeds the request
    /// (the country and area type are read from the preferences by the caller).
    func generate(using prefs: CookingPreferences) async {
        householdSize = max(1, min(prefs.householdSize, 12))
        dietaryPreferences = Array(prefs.dietaryPreferences)
        regionLabel = prefs.store?.shopperLabel
        optionsOverride = prefs.planOptions
        if let chosen = prefs.weeklyBudget { budget = chosen }
        budgetInputMessage = nil
        await generatePlan()
    }

    func generatePlan() async {
        phase = .generating
        let dietary = dietaryPreferences.filter { $0 != .noRestrictions }.map(\.displayName)
        let pantry = useKitchen ? pantryNames() : []
        do {
            let resp = try await generate(budget, householdSize, dietary, pantry, optionsOverride ?? options())
            guard !resp.recipes.isEmpty else {
                phase = .failed("We couldn't build a plan this time. Please try again.")
                return
            }
            apply(resp)
            phase = .results
            persist()
            if resp.isFree {
                // The free plan is the account's only one: keep its recipes in the
                // library so it can never be lost, and say so once.
                onFreePlanGenerated(recipes.map(\.recipe))
                flashFreeSavedToast()
            }
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
        refreshAddedState()
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
            let old = recipes[result.mealIndex].recipe
            withAnimation(.easeInOut(duration: 0.35)) {
                recipes[result.mealIndex] = result.meal
                total = result.planTotal
                swapsRemaining = result.swapsRemaining
            }
            if response?.isFree == true { onMealSwapped(old, result.meal.recipe) }
            persist()
            refreshAddedState()
        } catch BudgetPlanError.freeSwapsUsed {
            swapsRemaining = 0
            persist()
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

    // MARK: Meal Plan (always the user's choice)

    /// Every dinner is already in the Meal Plan.
    var weekAdded: Bool { !recipes.isEmpty && recipes.allSatisfy { addedIDs.contains($0.id) } }
    func isAdded(_ id: String) -> Bool { addedIDs.contains(id) }

    /// Re-derive which dinners are in the Meal Plan (also picks up removals made
    /// on the Meal Plan tab).
    func refreshAddedState() {
        addedIDs = Set(recipes.map(\.id).filter(isInMealPlan))
    }

    /// "Add week to Meal Plan": adds only the dinners not already there, each onto
    /// the next open day (never over an existing dinner).
    func addWeekToMealPlan() {
        let missing = recipes.filter { !addedIDs.contains($0.id) }
        guard !missing.isEmpty else { return }
        commit(missing)
        refreshAddedState()
    }

    /// Add one dinner to the next open day.
    func addDinnerToMealPlan(at index: Int) {
        guard recipes.indices.contains(index), !addedIDs.contains(recipes[index].id) else { return }
        addDinnerToMealPlan(recipes[index])
        refreshAddedState()
    }

    // MARK: New plan

    /// Pro (or any non-free plan): back to setup. A free plan's account has used
    /// its one plan, so go straight to the paywall — no generate call just to get
    /// a 403. If they subscribe from it, `paywallDismissed` continues to setup.
    func newPlan() {
        if response?.isFree == true {
            newPlanPending = true
            showPaywall = true
        } else {
            startOver()
        }
    }

    func paywallDismissed(isPro: Bool) {
        showPaywall = false
        if newPlanPending && isPro { startOver() }
        newPlanPending = false
    }

    func startOver() { phase = .setup }

    /// The quiz was dismissed without building: back to the plan on screen, if any.
    func cancelSetup() { phase = recipes.isEmpty ? .setup : .results }

    private func flashFreeSavedToast() {
        showFreeSavedToast = true
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            self?.showFreeSavedToast = false
        }
    }
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
    private let onOpenMealPlan: () -> Void
    private let userScope: String?
    /// DEBUG/QA only: auto-run generation on appear so the results state can be
    /// screenshotted. Always false in production.
    private let autoGenerate: Bool
    @State private var didAutoGenerate = false
    /// Right after onboarding: build the first week from the quiz answers as soon
    /// as the tab opens (showing the loading state, never the quiz again).
    private let launchPending: Bool
    private let onLaunch: (BudgetPlanModel) -> Void
    @State private var didLaunch = false

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
        addDinner: @escaping (_ recipe: PlannedRecipe) -> Void = { _ in },
        isInMealPlan: @escaping (_ recipeId: String) -> Bool = { _ in false },
        savedPlanStore: SavedBudgetPlanStore? = nil,
        onFreePlanGenerated: @escaping (_ recipes: [Recipe]) -> Void = { _ in },
        onMealSwapped: @escaping (_ old: Recipe, _ new: Recipe) -> Void = { _, _ in },
        onOpenMealPlan: @escaping () -> Void,
        autoGenerate: Bool = false,
        launchPending: Bool = false,
        onLaunch: @escaping (BudgetPlanModel) -> Void = { _ in }
    ) {
        let built = BudgetPlanModel(
            householdSize: householdSize,
            dietaryPreferences: dietary,
            regionLabel: regionLabel,
            pantryNames: pantryNames,
            options: options,
            generate: generate,
            swap: swap,
            commit: commit,
            addDinner: addDinner,
            isInMealPlan: isInMealPlan,
            savedPlanStore: savedPlanStore,
            onFreePlanGenerated: onFreePlanGenerated,
            onMealSwapped: onMealSwapped
        )
        // Straight to the loading state: the quiz must not flash before the launch
        // generation starts.
        if launchPending { built.phase = .generating }
        _model = StateObject(wrappedValue: built)
        self.onOpenMealPlan = onOpenMealPlan
        self.userScope = userScope
        self.autoGenerate = autoGenerate
        self.launchPending = launchPending
        self.onLaunch = onLaunch
    }

    var body: some View {
        BudgetPlanView(model: model, userScope: userScope, onOpenMealPlan: onOpenMealPlan)
            .task {
                if launchPending && !didLaunch {
                    didLaunch = true
                    onLaunch(model)
                }
                if autoGenerate && !didAutoGenerate {
                    didAutoGenerate = true
                    await model.generatePlan()
                    #if DEBUG
                    // Screenshot harness: `-debugOpenSheet` opens the first dinner's
                    // sheet; `-debugSwapping` also starts a (slow, stubbed) swap.
                    let args = ProcessInfo.processInfo.arguments
                    if args.contains("-debugOpenSheet") || args.contains("-debugSwapping") {
                        model.selectedMealIndex = 0
                    }
                    if args.contains("-debugSwapping") || args.contains("-debugSwapCard") {
                        Task { await model.swapMeal(at: 0) }
                    }
                    #endif
                }
            }
    }
}

// MARK: - Root

struct BudgetPlanView: View {
    @ObservedObject var model: BudgetPlanModel
    @EnvironmentObject private var subscriptions: SubscriptionService
    @EnvironmentObject private var cookingPreferences: CookingPreferencesModel
    var userScope: String? = nil
    /// Opens the Meal Plan tab ("Added to Meal Plan ✓").
    var onOpenMealPlan: () -> Void = {}

    @State private var quiz: PlanQuizModel?
    @State private var showingQuiz = false

    var body: some View {
        Group {
            switch model.phase {
            case .setup: BudgetSetupLanding(onStart: openQuiz)
            case .generating: BudgetGeneratingView()
            case .results: BudgetResultsView(model: model, userScope: userScope, onOpenMealPlan: onOpenMealPlan)
            case .failed(let message): failedState(message)
            }
        }
        // The paywall hangs off the meal sheet when it's open (a sheet can't be
        // presented over a presenting view that already has one), else off the root.
        .sheet(isPresented: Binding(
            get: { model.showPaywall && model.selectedMealIndex == nil },
            set: { if !$0 { model.showPaywall = false } }
        ), onDismiss: { model.paywallDismissed(isPro: subscriptions.isProUnlocked) }) {
            PlatterProPaywallView().environmentObject(subscriptions)
        }
        // Setup runs as a full-screen quiz: the first time Plan on a Budget opens
        // with no saved plan (existing users answer Mood → Appliances → Store →
        // Budget once), after "New plan", and after "Change my answers".
        .fullScreenCover(isPresented: $showingQuiz) {
            if let quiz {
                PlanQuizFlow(model: quiz, onExit: cancelQuiz, onFinish: buildWeek)
            }
        }
        .onAppear { if model.phase == .setup && !model.showPaywall { openQuiz() } }
        .onChange(of: model.phase) { _, phase in
            // A paywall bounce (generating → setup while the paywall opens) must not
            // stack the quiz on top of it.
            if phase == .setup && !model.showPaywall { openQuiz() }
        }
    }

    /// Existing answers are pre-filled; the budget pre-fills from the last one used.
    private func openQuiz() {
        guard !showingQuiz else { return }
        let lastBudget = SavedBudgetPlanStore(userScope: userScope).load().map { Int($0.budget.rounded()) }
        quiz = PlanQuizModel(session: .planSetup(
            from: cookingPreferences.preferences,
            deviceCountry: GroceryCountry.guessFromLocale(),
            lastBudget: lastBudget
        ))
        showingQuiz = true
    }

    private func cancelQuiz() {
        showingQuiz = false
        model.cancelSetup()
    }

    private func buildWeek(_ answers: CookingPreferences) {
        cookingPreferences.save(answers)
        showingQuiz = false
        Task { await model.generate(using: cookingPreferences.preferences) }
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
            Button("Try Again") { Task { await model.generate(using: cookingPreferences.preferences) } }
                .font(.headline)
                .foregroundStyle(Color.accentColor)
                .frame(minHeight: 44)
            Button("Change my answers") { model.startOver() }
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)
                .frame(minHeight: 44)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Setup landing

/// Shown behind the quiz, and after it's dismissed without building a week.
private struct BudgetSetupLanding: View {
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Plan on a budget")
                .font(.editorialTitle(size: 32, relativeTo: .largeTitle))
                .accessibilityAddTraits(.isHeader)
            Text("Answer a few questions and we'll build a week of dinners around your budget, kitchen and store.")
                .font(.system(size: 16))
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onStart) {
                Text("Plan my week")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
