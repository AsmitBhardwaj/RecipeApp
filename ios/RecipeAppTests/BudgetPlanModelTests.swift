//
//  BudgetPlanModelTests.swift
//  RecipeAppTests
//
//  "Your week" behavior: server-driven swap counts, paywall routing for 403/402,
//  in-place swap with the server's new total, retryable failures, and plans with
//  fewer than seven dinners.
//

import XCTest
@testable import RecipeApp
import RecipeKit

@MainActor
final class BudgetPlanModelTests: XCTestCase {

    private func recipe(_ id: String, _ title: String) -> Recipe {
        Recipe(
            recipeId: id, canonicalVideoId: "budget:\(id)", title: title,
            servings: Servings(amount: 2, unit: nil), prepTimeMinutes: nil, cookTimeMinutes: nil,
            totalTimeMinutes: nil, ingredients: [], instructions: [], confidence: nil,
            sourceType: .generated, imageUrl: nil, imageSource: .none, transcript: nil
        )
    }

    private func planned(_ id: String, cost: Double) -> PlannedRecipe {
        PlannedRecipe(recipe: recipe(id, "Meal \(id)"), estimatedCost: CostEstimate(amount: cost), healthSignal: "")
    }

    private func response(dinners: Int = 5, swaps: Int? = 3) -> BudgetPlanResponse {
        BudgetPlanResponse(
            recipes: (1...dinners).map { planned("m\($0)", cost: 10) }, currency: "USD", budget: 75,
            minBudget: 50, regionalMultiplier: 1, planId: "plan1", isFree: swaps != nil, swapsRemaining: swaps
        )
    }

    private func swapResult(index: Int, total: Double = 43, remaining: Int? = 2) -> BudgetSwapResponse {
        BudgetSwapResponse(
            planId: "plan1", mealIndex: index, meal: planned("new", cost: 3), planTotal: total,
            budget: 75, swapsUsed: 1, swapsRemaining: remaining
        )
    }

    private func makeModel(
        generate: @escaping BudgetPlanModel.Generate,
        swap: @escaping BudgetPlanModel.Swap = { _, _ in throw BudgetPlanError.http(500) }
    ) -> BudgetPlanModel {
        BudgetPlanModel(
            householdSize: 2, dietaryPreferences: [], pantryNames: { [] },
            generate: generate, swap: swap, commit: { _ in }
        )
    }

    func testFreeFirstPlanShowsServerSwapCount() async {
        let model = makeModel(generate: { _, _, _, _, _ in self.response(swaps: 3) })
        await model.generatePlan()
        XCTAssertEqual(model.phase, .results)
        XCTAssertEqual(model.swapsRemaining, 3)
        XCTAssertEqual(model.total, 50)
        XCTAssertFalse(model.showPaywall)
    }

    func testProAccountHasNoPill() async {
        let model = makeModel(generate: { _, _, _, _, _ in self.response(swaps: nil) })
        await model.generatePlan()
        XCTAssertNil(model.swapsRemaining)
    }

    func testFewerThanSevenDinnersRenderAnyCount() async {
        for n in [1, 3, 7] {
            let model = makeModel(generate: { _, _, _, _, _ in self.response(dinners: n) })
            await model.generatePlan()
            XCTAssertEqual(model.phase, .results)
            XCTAssertEqual(model.dinnerCount, n)
        }
    }

    func testSecondPlanOnFreeAccountOpensPaywall() async {
        for error in [BudgetPlanError.freePlanUsed, .proRequired] {
            let model = makeModel(generate: { _, _, _, _, _ in throw error })
            await model.generatePlan()
            XCTAssertTrue(model.showPaywall)
            XCTAssertEqual(model.phase, .setup, "back to setup, never a blank screen")
        }
    }

    func testGenerationFailureShowsRetryableFailedState() async {
        let model = makeModel(generate: { _, _, _, _, _ in throw BudgetPlanError.http(500) })
        await model.generatePlan()
        guard case .failed = model.phase else { return XCTFail("expected failed, got \(model.phase)") }
    }

    func testEmptyPlanIsAFailureNotABlankScreen() async {
        let empty = BudgetPlanResponse(recipes: [], currency: "USD", budget: 75, minBudget: 50, regionalMultiplier: 1)
        let model = makeModel(generate: { _, _, _, _, _ in empty })
        await model.generatePlan()
        guard case .failed = model.phase else { return XCTFail("expected failed") }
    }

    func testSwapReplacesInPlaceAndUsesServerTotalAndCount() async {
        let model = makeModel(
            generate: { _, _, _, _, _ in self.response(swaps: 3) },
            swap: { planID, index in
                XCTAssertEqual(planID, "plan1")
                return self.swapResult(index: index, total: 43, remaining: 2)
            }
        )
        await model.generatePlan()
        await model.swapMeal(at: 1)
        XCTAssertEqual(model.recipes[1].recipe.recipeId, "new")
        XCTAssertEqual(model.recipes[0].recipe.recipeId, "m1", "neighbours untouched")
        XCTAssertEqual(model.total, 43, "server total, not summed client-side")
        XCTAssertEqual(model.swapsRemaining, 2)
        XCTAssertNil(model.swappingIndex)
        XCTAssertNil(model.swapFailure)
    }

    func testOutOfSwapsOpensPaywall() async {
        let model = makeModel(
            generate: { _, _, _, _, _ in self.response(swaps: 1) },
            swap: { _, _ in throw BudgetPlanError.freeSwapsUsed }
        )
        await model.generatePlan()
        await model.swapMeal(at: 0)
        XCTAssertTrue(model.showPaywall)
        XCTAssertEqual(model.recipes[0].recipe.recipeId, "m1", "meal untouched")
        XCTAssertNil(model.swapFailure)
    }

    func testConstraintUnmetIsFriendlyAndRetryable() async {
        var attempts = 0
        let model = makeModel(
            generate: { _, _, _, _, _ in self.response(swaps: 3) },
            swap: { _, index in
                attempts += 1
                if attempts == 1 { throw BudgetPlanError.constraintUnmet }
                return self.swapResult(index: index)
            }
        )
        await model.generatePlan()
        await model.swapMeal(at: 2)
        XCTAssertEqual(model.swapFailure?.message, "Couldn't find a swap that fits — try again.")
        XCTAssertEqual(model.swapsRemaining, 3, "no swap consumed")
        XCTAssertFalse(model.showPaywall)

        await model.retrySwap()
        XCTAssertNil(model.swapFailure)
        XCTAssertEqual(model.recipes[2].recipe.recipeId, "new")
        XCTAssertEqual(model.swapsRemaining, 2)
    }

    func testAddWeekCommitsEveryDinnerNotAlreadyAdded() async {
        var committed: [PlannedRecipe] = []
        var inPlan: Set<String> = []
        let model = BudgetPlanModel(
            householdSize: 2, dietaryPreferences: [], pantryNames: { [] },
            generate: { _, _, _, _, _ in self.response(dinners: 4) },
            swap: { _, _ in throw BudgetPlanError.http(500) },
            commit: { committed = $0; inPlan.formUnion($0.map(\.id)) },
            isInMealPlan: { inPlan.contains($0) }
        )
        await model.generatePlan()
        XCTAssertFalse(model.weekAdded)
        model.addWeekToMealPlan()
        XCTAssertEqual(committed.count, 4)
        XCTAssertTrue(model.weekAdded)

        // Adding again is a no-op (button now opens the Meal Plan tab instead).
        committed = []
        model.addWeekToMealPlan()
        XCTAssertTrue(committed.isEmpty)
    }

    func testAddWeekSkipsDinnersAlreadyInMealPlan() async {
        var committed: [PlannedRecipe] = []
        var inPlan: Set<String> = ["m2"]
        let model = BudgetPlanModel(
            householdSize: 2, dietaryPreferences: [], pantryNames: { [] },
            generate: { _, _, _, _, _ in self.response(dinners: 3) },
            swap: { _, _ in throw BudgetPlanError.http(500) },
            commit: { committed = $0; inPlan.formUnion($0.map(\.id)) },
            isInMealPlan: { inPlan.contains($0) }
        )
        await model.generatePlan()
        model.addWeekToMealPlan()
        XCTAssertEqual(committed.map(\.id), ["m1", "m3"])
    }

    func testSingleDinnerAddMarksOnlyThatDinner() async {
        var added: [String] = []
        var inPlan: Set<String> = []
        let model = BudgetPlanModel(
            householdSize: 2, dietaryPreferences: [], pantryNames: { [] },
            generate: { _, _, _, _, _ in self.response(dinners: 3) },
            swap: { _, _ in throw BudgetPlanError.http(500) },
            commit: { _ in },
            addDinner: { added.append($0.id); inPlan.insert($0.id) },
            isInMealPlan: { inPlan.contains($0) }
        )
        await model.generatePlan()
        model.addDinnerToMealPlan(at: 1)
        model.addDinnerToMealPlan(at: 1)   // second tap: no double add
        XCTAssertEqual(added, ["m2"])
        XCTAssertTrue(model.isAdded("m2"))
        XCTAssertFalse(model.isAdded("m1"))
        XCTAssertFalse(model.weekAdded)
    }

    // MARK: Persistence, library hooks, New plan

    private func freshStore() -> SavedBudgetPlanStore {
        SavedBudgetPlanStore(defaults: UserDefaults(suiteName: "budgetmodel-\(UUID().uuidString)")!, userScope: "u")
    }

    private func persistedModel(
        store: SavedBudgetPlanStore,
        swaps: Int? = 3,
        swap: @escaping BudgetPlanModel.Swap = { _, _ in throw BudgetPlanError.http(500) },
        onFree: @escaping ([Recipe]) -> Void = { _ in },
        onSwapped: @escaping (Recipe, Recipe) -> Void = { _, _ in }
    ) -> BudgetPlanModel {
        BudgetPlanModel(
            householdSize: 2, dietaryPreferences: [], regionLabel: "Canada", pantryNames: { [] },
            generate: { _, _, _, _, _ in self.response(swaps: swaps) }, swap: swap, commit: { _ in },
            savedPlanStore: store, onFreePlanGenerated: onFree, onMealSwapped: onSwapped
        )
    }

    func testFreePlanIsSavedToLibraryOnceAndToastShown() async {
        var saved: [[Recipe]] = []
        let model = persistedModel(store: freshStore(), swaps: 3, onFree: { saved.append($0) })
        await model.generatePlan()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].map(\.recipeId), ["m1", "m2", "m3", "m4", "m5"])
        XCTAssertTrue(model.showFreeSavedToast)
    }

    func testProPlanIsNotAutoSavedButIsPersisted() async {
        var saved = 0
        let store = freshStore()
        let model = persistedModel(store: store, swaps: nil, onFree: { _ in saved += 1 })
        await model.generatePlan()
        XCTAssertEqual(saved, 0)
        XCTAssertFalse(model.showFreeSavedToast)
        XCTAssertEqual(store.load()?.isFree, false)
        XCTAssertEqual(store.load()?.recipes.count, 5)
    }

    func testReopeningRestoresYourWeekWithSwapsWorking() async {
        let store = freshStore()
        let first = persistedModel(store: store, swaps: 3, swap: { _, index in self.swapResult(index: index, total: 43, remaining: 2) })
        await first.generatePlan()
        await first.swapMeal(at: 0)

        var swappedPlanID: String?
        let reopened = persistedModel(store: store, swap: { planID, index in
            swappedPlanID = planID
            return self.swapResult(index: index, total: 40, remaining: 1)
        })
        XCTAssertEqual(reopened.phase, .results, "restored, not setup")
        XCTAssertEqual(reopened.recipes[0].recipe.recipeId, "new")
        XCTAssertEqual(reopened.total, 43)
        XCTAssertEqual(reopened.swapsRemaining, 2)
        XCTAssertEqual(reopened.regionLabel, "Canada")
        XCTAssertFalse(reopened.showFreeSavedToast, "toast is for generation only")

        await reopened.swapMeal(at: 1)
        XCTAssertEqual(swappedPlanID, "plan1")
        XCTAssertEqual(reopened.swapsRemaining, 1)
    }

    func testSwapOnFreePlanNotifiesLibraryProSwapDoesNot() async {
        var pairs: [(String, String)] = []
        let free = persistedModel(store: freshStore(), swaps: 3,
                                  swap: { _, i in self.swapResult(index: i) }, onSwapped: { pairs.append(($0.recipeId, $1.recipeId)) })
        await free.generatePlan()
        await free.swapMeal(at: 2)
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].0, "m3")
        XCTAssertEqual(pairs[0].1, "new")

        pairs = []
        let pro = persistedModel(store: freshStore(), swaps: nil,
                                 swap: { _, i in self.swapResult(index: i, remaining: nil) }, onSwapped: { pairs.append(($0.recipeId, $1.recipeId)) })
        await pro.generatePlan()
        await pro.swapMeal(at: 2)
        XCTAssertTrue(pairs.isEmpty)
    }

    func testNewPlanOnFreePlanOpensPaywallWithoutGenerating() async {
        var generateCalls = 0
        let model = BudgetPlanModel(
            householdSize: 2, dietaryPreferences: [], pantryNames: { [] },
            generate: { _, _, _, _, _ in generateCalls += 1; return self.response(swaps: 3) },
            swap: { _, _ in throw BudgetPlanError.http(500) }, commit: { _ in }
        )
        await model.generatePlan()
        model.newPlan()
        XCTAssertTrue(model.showPaywall)
        XCTAssertEqual(model.phase, .results)
        XCTAssertEqual(generateCalls, 1, "no generate just to get a 403")

        // Dismissed without subscribing: stay on the plan.
        model.paywallDismissed(isPro: false)
        XCTAssertEqual(model.phase, .results)
        XCTAssertFalse(model.showPaywall)
    }

    func testNewPlanFromPaywallContinuesToSetupIfTheyBecomePro() async {
        let model = makeModel(generate: { _, _, _, _, _ in self.response(swaps: 3) })
        await model.generatePlan()
        model.newPlan()
        model.paywallDismissed(isPro: true)
        XCTAssertEqual(model.phase, .setup)
    }

    func testNewPlanOnProPlanGoesStraightToSetup() async {
        let model = makeModel(generate: { _, _, _, _, _ in self.response(swaps: nil) })
        await model.generatePlan()
        model.newPlan()
        XCTAssertEqual(model.phase, .setup)
        XCTAssertFalse(model.showPaywall)
    }

    func testV1ShapedOptionsAreEmptyByDefault() async {
        var received: BudgetPlanOptions?
        let model = makeModel(generate: { _, _, _, _, options in received = options; return self.response() })
        await model.generatePlan()
        XCTAssertEqual(received, BudgetPlanOptions.none)
    }
}
