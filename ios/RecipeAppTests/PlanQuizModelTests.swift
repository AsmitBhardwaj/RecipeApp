//
//  PlanQuizModelTests.swift
//  RecipeAppTests
//
//  App-layer wiring for the plan quiz: generating from the saved answers (household,
//  diet, moods, appliances, store tier, budget), cancelling setup, the onboarding →
//  Plan on a Budget launch flag, saving a draft, and refreshing from a sync pull.
//

import XCTest
@testable import RecipeApp
import RecipeKit

@MainActor
final class PlanQuizModelTests: XCTestCase {

    private var scopes: [String] = []

    override func tearDown() {
        for scope in scopes { AccountDataEraser.erase(userId: scope) }
        scopes = []
        super.tearDown()
    }

    private func makePrefsModel(legacyCompletion: Bool = true) -> CookingPreferencesModel {
        let scope = "plan-quiz-tests-\(UUID().uuidString)"
        scopes.append(scope)
        return CookingPreferencesModel(userScope: scope, legacyCompletion: legacyCompletion)
    }

    private func recipe(_ id: String) -> Recipe {
        Recipe(
            recipeId: id, canonicalVideoId: "budget:\(id)", title: "Meal \(id)",
            servings: Servings(amount: 2, unit: nil), prepTimeMinutes: nil, cookTimeMinutes: nil,
            totalTimeMinutes: nil, ingredients: [], instructions: [], confidence: nil,
            sourceType: .generated, imageUrl: nil, imageSource: .none, transcript: nil
        )
    }

    private func response() -> BudgetPlanResponse {
        BudgetPlanResponse(
            recipes: [PlannedRecipe(recipe: recipe("a"), estimatedCost: CostEstimate(amount: 10), healthSignal: "")],
            currency: "USD", budget: 150, minBudget: 50, regionalMultiplier: 1
        )
    }

    private var answers: CookingPreferences {
        CookingPreferences(
            dietaryPreferences: [.vegetarian, .nutFree], householdSize: 4, country: "US",
            foodMoods: [.spicy, .quick], appliances: [.oven, .stovetop], storeName: "Aldi",
            weeklyBudget: 150, hasCompletedOnboarding: true
        )
    }

    // MARK: Generate from answers

    func testGenerateUsingAnswersSendsEveryQuizField() async {
        var captured: (budget: Int, household: Int, dietary: [String], options: BudgetPlanOptions)?
        let model = BudgetPlanModel(
            householdSize: 2, dietaryPreferences: [], pantryNames: { [] },
            generate: { budget, household, dietary, _, options in
                captured = (budget, household, dietary, options)
                return self.response()
            },
            swap: { _, _ in throw BudgetPlanError.http(500) }, commit: { _ in }
        )
        await model.generate(using: answers)

        XCTAssertEqual(captured?.budget, 150)
        XCTAssertEqual(captured?.household, 4)
        XCTAssertEqual(Set(captured?.dietary ?? []), ["Vegetarian", "Nut-free"])
        XCTAssertEqual(captured?.options, BudgetPlanOptions(
            storeTier: "budget", appliances: ["stovetop", "oven"], foodMoods: ["spicy", "quick"]
        ))
        XCTAssertEqual(model.regionLabel, "Aldi")            // "Estimated for Aldi shoppers"
        XCTAssertEqual(model.householdSize, 4)
        XCTAssertEqual(model.phase, .results)
    }

    func testNoRestrictionsIsNotSentAsADietAndOtherStoreHasNoLabel() async {
        var dietary: [String]?
        let model = BudgetPlanModel(
            householdSize: 2, dietaryPreferences: [], pantryNames: { [] },
            generate: { _, _, d, _, _ in dietary = d; return self.response() },
            swap: { _, _ in throw BudgetPlanError.http(500) }, commit: { _ in }
        )
        var prefs = answers
        prefs.dietaryPreferences = [.noRestrictions]
        prefs.storeName = "Other"
        await model.generate(using: prefs)
        XCTAssertEqual(dietary, [])
        XCTAssertNil(model.regionLabel)
    }

    func testCancelSetupReturnsToPlanOrStaysInSetup() async {
        let model = BudgetPlanModel(
            householdSize: 2, dietaryPreferences: [], pantryNames: { [] },
            generate: { _, _, _, _, _ in self.response() },
            swap: { _, _ in throw BudgetPlanError.http(500) }, commit: { _ in }
        )
        model.startOver()
        model.cancelSetup()
        XCTAssertEqual(model.phase, .setup)                  // nothing to go back to

        await model.generatePlan()
        model.startOver()                                    // "New plan"
        XCTAssertEqual(model.phase, .setup)
        model.cancelSetup()                                  // dismiss the quiz
        XCTAssertEqual(model.phase, .results)
    }

    // MARK: Preferences model

    func testSaveDraftPersistsAndKeepsOnboardingFlag() {
        let prefs = makePrefsModel()
        XCTAssertTrue(prefs.hasCompletedOnboarding)
        var draft = answers
        draft.hasCompletedOnboarding = false                 // a stale draft can't un-onboard
        prefs.save(draft)
        XCTAssertTrue(prefs.hasCompletedOnboarding)
        XCTAssertEqual(prefs.preferences.storeName, "Aldi")
        XCTAssertEqual(prefs.preferences.appliances, [.oven, .stovetop])
        XCTAssertEqual(CookingPreferencesStore(userScope: prefs.userScope).load()?.weeklyBudget, 150)
    }

    func testExistingUserSetupTriggerAtModelLevel() {
        let onboardedV1 = makePrefsModel(legacyCompletion: true)   // updated from 1.0
        XCTAssertTrue(onboardedV1.needsPlanSetup)
        onboardedV1.save(answers)
        XCTAssertFalse(onboardedV1.needsPlanSetup)
        XCTAssertFalse(makePrefsModel(legacyCompletion: false).needsPlanSetup)   // still onboarding
    }

    func testLaunchFlagIsInMemoryAndConsumedOnce() {
        let prefs = makePrefsModel()
        XCTAssertFalse(prefs.pendingPlanBuild)
        prefs.requestPlanBuild()
        XCTAssertTrue(prefs.pendingPlanBuild)
        prefs.consumePlanBuildRequest()
        XCTAssertFalse(prefs.pendingPlanBuild)
    }

    func testRefreshFromStorePicksUpASyncPullAndCompletesOnboarding() {
        let prefs = makePrefsModel(legacyCompletion: false)
        XCTAssertFalse(prefs.hasCompletedOnboarding)
        // What LocalSyncApplier does on a pull: write straight to the store.
        CookingPreferencesStore(userScope: prefs.userScope).save(answers)
        prefs.refreshFromStore()
        XCTAssertTrue(prefs.hasCompletedOnboarding)          // reinstall skips the quiz
        XCTAssertEqual(prefs.preferences.storeName, "Aldi")
    }

    // MARK: New plan pre-fill (through the same factory the quiz uses)

    func testNewPlanSessionPrefillsFromSavedAnswersAndLastPlanBudget() {
        let prefs = makePrefsModel()
        var partial = answers
        partial.weeklyBudget = nil
        prefs.save(partial)
        let session = PlanQuizSession.planSetup(from: prefs.preferences, deviceCountry: "US", lastBudget: 120)
        XCTAssertEqual(session.step, .mood)
        XCTAssertEqual(session.draft.foodMoods, [.spicy, .quick])
        XCTAssertEqual(session.draft.appliances, [.oven, .stovetop])
        XCTAssertEqual(session.draft.storeName, "Aldi")
        XCTAssertEqual(session.budget, 120)
    }
}
