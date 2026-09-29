//
//  PlanQuizSession.swift
//  RecipeKit
//
//  The pure state machine behind the Plan on a Budget quiz. One session edits a
//  DRAFT copy of `CookingPreferences` across an ordered list of steps; nothing is
//  persisted until the caller saves the draft (on the last Continue, or on the
//  single Continue of an edit). Kept free of SwiftUI so the rules — diet
//  exclusivity, the mood cap, validity, pre-fill — are unit-testable.
//

import Foundation

public enum PlanQuizStep: String, CaseIterable, Hashable, Sendable {
    case people, diet, mood, appliances, store, budget

    /// The full first-run onboarding sequence.
    public static let onboarding: [PlanQuizStep] = [.people, .diet, .mood, .appliances, .store, .budget]
    /// Existing users / "New plan": only the plan-specific screens.
    public static let planSetup: [PlanQuizStep] = [.mood, .appliances, .store, .budget]

    public var title: String {
        switch self {
        case .people: "How many people are you cooking for?"
        case .diet: "Any dietary needs?"
        case .mood: "What are you in the mood for?"
        case .appliances: "What can you cook with?"
        case .store: "Where do you usually shop?"
        case .budget: "What's your weekly budget?"
        }
    }

    public var subtitle: String {
        switch self {
        case .people: "Including you. Portions, groceries and budget scale with this."
        case .diet: "Pick all that apply. Every dinner will follow these."
        case .mood: "Pick up to three. We'll lean your week this way."
        case .appliances: "Tap everything in your kitchen. Every dinner will only use these."
        case .store: "We'll estimate prices for the store you actually use."
        case .budget: "For dinners only. We'll aim to use most of it, never more."
        }
    }

    /// Short name for the "Plan preferences" list in Account.
    public var editorTitle: String {
        switch self {
        case .people: "People"
        case .diet: "Diet"
        case .mood: "Food mood"
        case .appliances: "Appliances"
        case .store: "Store"
        case .budget: "Weekly budget"
        }
    }
}

/// "How many people" options. 6+ sends 6.
public enum PlanPeopleChoice {
    public static let options: [Int] = [1, 2, 3, 4, 5, 6]

    public static func label(for count: Int) -> String {
        switch count {
        case ...1: "Just me"
        case 6...: "6 or more"
        default: "\(count) people"
        }
    }

    /// The option a stored household size maps to (a stored 8 shows as "6 or more").
    public static func option(forHouseholdSize size: Int) -> Int { min(max(size, 1), 6) }
}

public struct PlanQuizSession: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case onboarding
        /// Existing-user setup and "New plan".
        case planSetup
        /// One screen opened from Account → Plan preferences.
        case edit(PlanQuizStep)
    }

    public let kind: Kind
    public let steps: [PlanQuizStep]
    public private(set) var index = 0
    public private(set) var draft: CookingPreferences
    /// False while the budget is just the computed default — it then follows the
    /// people / store / country answers. True once the user moved it or it was
    /// pre-filled from a previous plan.
    private var budgetIsUserChosen: Bool

    // MARK: Factories

    /// First-run onboarding: all six screens. An empty diet defaults to "No
    /// restrictions"; the country defaults from the device region.
    public static func onboarding(from prefs: CookingPreferences, deviceCountry: String?) -> PlanQuizSession {
        var draft = prefs
        if draft.dietaryPreferences.isEmpty { draft.dietaryPreferences = [.noRestrictions] }
        if draft.country == nil { draft.country = deviceCountry }
        return PlanQuizSession(kind: .onboarding, steps: PlanQuizStep.onboarding, draft: draft)
    }

    /// Existing-user setup and "New plan": Mood → Appliances → Store → Budget with
    /// every current answer pre-filled. The budget pre-fills from the last one
    /// used (`lastBudget` is the fallback for accounts that predate the stored one).
    public static func planSetup(from prefs: CookingPreferences, deviceCountry: String?, lastBudget: Int? = nil) -> PlanQuizSession {
        var draft = prefs
        if draft.country == nil { draft.country = deviceCountry }
        if draft.weeklyBudget == nil { draft.weeklyBudget = lastBudget }
        return PlanQuizSession(kind: .planSetup, steps: PlanQuizStep.planSetup, draft: draft)
    }

    /// A single screen, saved on Continue.
    public static func edit(_ step: PlanQuizStep, from prefs: CookingPreferences, deviceCountry: String?) -> PlanQuizSession {
        var draft = prefs
        if draft.country == nil { draft.country = deviceCountry }
        return PlanQuizSession(kind: .edit(step), steps: [step], draft: draft)
    }

    private init(kind: Kind, steps: [PlanQuizStep], draft: CookingPreferences) {
        self.kind = kind
        self.steps = steps
        self.draft = draft
        self.budgetIsUserChosen = draft.weeklyBudget != nil
        if steps.contains(.budget) { snapBudgetIntoBounds() }
    }

    // MARK: Navigation

    public var step: PlanQuizStep { steps[index] }
    public var isFirst: Bool { index == 0 }
    public var isLast: Bool { index == steps.count - 1 }
    /// Progress-bar fraction: this step out of the steps in THIS flow (6 or 4).
    public var progress: Double { Double(index + 1) / Double(steps.count) }
    public var canContinue: Bool { isValid(step) }

    /// Moves to the next step. Returns false (and stays put) on the last step or
    /// when the current answer isn't valid — the caller finishes instead.
    @discardableResult
    public mutating func advance() -> Bool {
        guard canContinue, !isLast else { return false }
        index += 1
        if step == .budget { snapBudgetIntoBounds() }
        return true
    }

    /// Moves back one step. Returns false at the first step (the caller exits).
    @discardableResult
    public mutating func back() -> Bool {
        guard !isFirst else { return false }
        index -= 1
        return true
    }

    // MARK: Validity

    public func isValid(_ step: PlanQuizStep) -> Bool {
        switch step {
        case .people: return (1...12).contains(draft.householdSize)
        case .diet: return !draft.dietaryPreferences.isEmpty
        case .mood: return true   // optional: 0 is valid
        case .appliances: return !draft.appliances.isEmpty
        case .store: return draft.storeName != nil
        case .budget: return draft.weeklyBudget != nil
        }
    }

    // MARK: Answers

    /// 6+ is stored as 6.
    public mutating func selectPeople(_ count: Int) {
        draft.householdSize = min(max(count, 1), 6)
        snapBudgetIntoBounds()
    }

    public mutating func toggleDiet(_ preference: DietaryPreference) {
        let selected = draft.dietaryPreferences.contains(preference)
        if preference == .noRestrictions {
            // Exclusive, and not toggle-off-able to an empty (invalid) state.
            draft.setDietaryPreference(.noRestrictions, selected: true)
        } else {
            draft.setDietaryPreference(preference, selected: !selected)
            // Deselecting the last restriction falls back to the default.
            if draft.dietaryPreferences.isEmpty { draft.dietaryPreferences = [.noRestrictions] }
        }
    }

    @discardableResult
    public mutating func toggleMood(_ mood: FoodMood) -> Bool { draft.toggleFoodMood(mood) }

    public mutating func toggleAppliance(_ appliance: Appliance) { draft.toggleAppliance(appliance) }

    public mutating func selectStore(_ store: PlanStore) {
        draft.setStore(store)
        snapBudgetIntoBounds()
    }

    public mutating func setCountry(_ code: String?) {
        draft.country = code
        snapBudgetIntoBounds()
    }

    // MARK: Budget

    /// The cost multiplier the server will apply for the current draft.
    public var multiplier: Double {
        RegionalCostMultiplier.multiplier(country: draft.country, storeTier: draft.storeTier)
    }

    public var budgetBounds: ClosedRange<Int> {
        PlanBudgetHelper.bounds(people: draft.householdSize, multiplier: multiplier)
    }

    public var typicalSpend: PlanBudgetHelper.TypicalSpend {
        PlanBudgetHelper.typicalSpend(people: draft.householdSize, multiplier: multiplier)
    }

    public var budget: Int { draft.weeklyBudget ?? PlanBudgetHelper.defaultBudget(people: draft.householdSize, multiplier: multiplier) }

    public mutating func setBudget(_ value: Int) {
        budgetIsUserChosen = true
        draft.weeklyBudget = PlanBudgetHelper.snapped(value, people: draft.householdSize, multiplier: multiplier)
    }

    /// +/- in $5 steps, clamped to the bounds.
    public mutating func stepBudget(by steps: Int) {
        setBudget(budget + steps * PlanBudgetHelper.increment)
    }

    /// Keeps the budget valid as people / store / country change: an untouched
    /// budget follows the typical low end; a chosen or pre-filled one is only
    /// clamped into the new bounds.
    public mutating func snapBudgetIntoBounds() {
        let people = draft.householdSize
        if let chosen = draft.weeklyBudget, budgetIsUserChosen {
            draft.weeklyBudget = PlanBudgetHelper.snapped(chosen, people: people, multiplier: multiplier)
        } else {
            draft.weeklyBudget = PlanBudgetHelper.defaultBudget(people: people, multiplier: multiplier)
        }
    }
}
