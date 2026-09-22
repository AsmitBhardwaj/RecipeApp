//
//  BudgetPlanTests.swift
//  RecipeKitTests
//
//  Budget math (per-person minimum, raise-only reconcile) and the pure
//  accept/save selection for a generated plan.
//

import XCTest
@testable import RecipeKit

final class BudgetPlanTests: XCTestCase {

    // MARK: - BudgetMath

    func testMinimumScalesPerPerson() {
        // Mirrors backend default MIN_BUDGET_PER_PERSON = 25.
        XCTAssertEqual(BudgetMath.minBudget(householdSize: 1), 25)
        XCTAssertEqual(BudgetMath.minBudget(householdSize: 2), 50)
        XCTAssertEqual(BudgetMath.minBudget(householdSize: 4), 100)
    }

    func testMinimumRoundsToNearestFive() {
        // 25 * 3 = 75 already a multiple of 5; verify the rounding path holds.
        XCTAssertEqual(BudgetMath.minBudget(householdSize: 3), 75)
        XCTAssertEqual(BudgetMath.minBudget(householdSize: 3) % 5, 0)
    }

    func testHouseholdClampedToAtLeastOne() {
        XCTAssertEqual(BudgetMath.minBudget(householdSize: 0), 25)
    }

    func testIncreasingHouseholdBumpsUnderMinimumBudgetUp() {
        // Budget $60 with 2 people (min 50) is fine; grow to 4 people (min 100) →
        // reconcile raises it to 100.
        let raised = BudgetMath.reconciled(currentBudget: 60, householdSize: 4)
        XCTAssertEqual(raised, 100)
    }

    func testAboveMinimumBudgetIsUnchanged() {
        // Household 2 (min 50); a $120 budget stays $120.
        XCTAssertEqual(BudgetMath.reconciled(currentBudget: 120, householdSize: 2), 120)
    }

    func testDecreasingHouseholdNeverLowersBudget() {
        // User chose to spend $120 for 4 people; dropping to 2 people (min 50)
        // must NOT reduce their budget — only-up, never-down.
        let afterDecrease = BudgetMath.reconciled(currentBudget: 120, householdSize: 2)
        XCTAssertEqual(afterDecrease, 120)
    }

    func testMinimumCaption() {
        XCTAssertEqual(BudgetMath.minimumCaption(householdSize: 1), "$25 minimum for 1 person")
        XCTAssertEqual(BudgetMath.minimumCaption(householdSize: 2), "$50 minimum for 2 people")
    }

    // MARK: - BudgetPlanSelection (accept / save)

    private func plannedRecipe(_ id: String, cost: Double) -> PlannedRecipe {
        let recipe = Recipe(
            recipeId: id,
            canonicalVideoId: "budget:\(id)",
            title: "Recipe \(id)",
            servings: Servings(amount: nil, unit: nil),
            prepTimeMinutes: nil,
            cookTimeMinutes: nil,
            totalTimeMinutes: nil,
            ingredients: [],
            instructions: [],
            confidence: nil,
            sourceType: .generated,
            imageUrl: nil,
            imageSource: .none,
            transcript: nil
        )
        return PlannedRecipe(recipe: recipe, estimatedCost: CostEstimate(amount: cost), healthSignal: "OK")
    }

    func testSelectionDefaultsToAllAccepted() {
        let recipes = [plannedRecipe("a", cost: 10), plannedRecipe("b", cost: 20)]
        let sel = BudgetPlanSelection(recipes: recipes)
        XCTAssertEqual(sel.acceptedCount, 2)
        XCTAssertEqual(sel.accepted(from: recipes).map(\.id), ["a", "b"])
        XCTAssertEqual(sel.totalCost(from: recipes), 30, accuracy: 0.001)
    }

    func testTogglingRecipeOffRemovesItFromSaveAndTotal() {
        let recipes = [plannedRecipe("a", cost: 10), plannedRecipe("b", cost: 20)]
        var sel = BudgetPlanSelection(recipes: recipes)
        sel.toggle("a")
        XCTAssertFalse(sel.isAccepted("a"))
        XCTAssertEqual(sel.accepted(from: recipes).map(\.id), ["b"])
        XCTAssertEqual(sel.totalCost(from: recipes), 20, accuracy: 0.001)
    }

    func testTogglingBackOnRestoresIt() {
        let recipes = [plannedRecipe("a", cost: 10)]
        var sel = BudgetPlanSelection(recipes: recipes)
        sel.toggle("a")
        sel.toggle("a")
        XCTAssertTrue(sel.isAccepted("a"))
        XCTAssertEqual(sel.acceptedCount, 1)
    }

    // MARK: - Decoding

    func testDecodesServerResponse() throws {
        let json = """
        {
          "recipes": [
            {
              "recipe": {"recipe_id":"r1","canonical_video_id":"budget:r1","title":"Chili",
                "servings":{"amount":null,"unit":null},"prep_time_minutes":null,"cook_time_minutes":null,
                "total_time_minutes":null,"ingredients":[],"instructions":[],
                "confidence":{"overall":0.5,"ingredients_complete":true,"instructions_complete":true,"missing_fields":[]},
                "source_type":"generated","image_url":null,"image_source":"none"},
              "estimated_cost": {"amount": 13.5, "currency": "USD", "basis": "llm-v1×regional"},
              "health_signal": "High protein"
            }
          ],
          "currency": "USD", "budget": 100.0, "min_budget": 50, "regional_multiplier": 1.35
        }
        """
        let resp = try JSONDecoder().decode(BudgetPlanResponse.self, from: Data(json.utf8))
        XCTAssertEqual(resp.recipes.count, 1)
        XCTAssertEqual(resp.recipes[0].estimatedCost.amount, 13.5, accuracy: 0.001)
        XCTAssertEqual(resp.recipes[0].healthSignal, "High protein")
        XCTAssertEqual(resp.minBudget, 50)
        XCTAssertEqual(resp.regionalMultiplier, 1.35, accuracy: 0.001)
    }
}
