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

    func testUsePlanCommitsEveryDinner() async {
        var committed: [PlannedRecipe] = []
        let model = BudgetPlanModel(
            householdSize: 2, dietaryPreferences: [], pantryNames: { [] },
            generate: { _, _, _, _, _ in self.response(dinners: 4) },
            swap: { _, _ in throw BudgetPlanError.http(500) },
            commit: { committed = $0 }
        )
        await model.generatePlan()
        model.usePlan()
        XCTAssertEqual(committed.count, 4)
    }

    func testV1ShapedOptionsAreEmptyByDefault() async {
        var received: BudgetPlanOptions?
        let model = makeModel(generate: { _, _, _, _, options in received = options; return self.response() })
        await model.generatePlan()
        XCTAssertEqual(received, BudgetPlanOptions.none)
    }
}
