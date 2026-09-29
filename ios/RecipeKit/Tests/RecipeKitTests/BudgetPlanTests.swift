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
        // Nominal mirror of the derived server model: floor $3 × min_count 4 = $12/person.
        XCTAssertEqual(BudgetMath.minBudget(householdSize: 1), 10)   // 12 -> 10
        XCTAssertEqual(BudgetMath.minBudget(householdSize: 2), 25)   // 24 -> 25
        XCTAssertEqual(BudgetMath.minBudget(householdSize: 4), 50)   // 48 -> 50
    }

    func testMaximumScalesPerPerson() {
        // Nominal cap: ceiling $12 × max_count 7 = $84/person.
        XCTAssertEqual(BudgetMath.maxBudget(householdSize: 1), 85)   // 84 -> 85
        XCTAssertEqual(BudgetMath.maxBudget(householdSize: 2), 170)  // 168 -> 170
        XCTAssertEqual(BudgetMath.maxBudget(householdSize: 4), 335)  // 336 -> 335
    }

    func testMinimumRoundsToNearestFive() {
        // 12 * 3 = 36 -> nearest $5 = 35.
        XCTAssertEqual(BudgetMath.minBudget(householdSize: 3), 35)
        XCTAssertEqual(BudgetMath.minBudget(householdSize: 3) % 5, 0)
    }

    func testHouseholdClampedToAtLeastOne() {
        XCTAssertEqual(BudgetMath.minBudget(householdSize: 0), BudgetMath.minBudget(householdSize: 1))
    }

    func testIncreasingHouseholdBumpsUnderMinimumBudgetUp() {
        // $20 with 4 people is below the $50 min → reconcile raises it to 50.
        let raised = BudgetMath.reconciled(currentBudget: 20, householdSize: 4)
        XCTAssertEqual(raised, 50)
    }

    func testAboveMinimumBudgetIsUnchanged() {
        // Household 2 (min 25); a $120 budget stays $120.
        XCTAssertEqual(BudgetMath.reconciled(currentBudget: 120, householdSize: 2), 120)
    }

    func testDecreasingHouseholdNeverLowersBudget() {
        // User chose to spend $120 for 4 people; dropping to 2 people (min 25)
        // must NOT reduce their budget — only-up, never-down.
        let afterDecrease = BudgetMath.reconciled(currentBudget: 120, householdSize: 2)
        XCTAssertEqual(afterDecrease, 120)
    }

    func testMinimumCaption() {
        XCTAssertEqual(BudgetMath.minimumCaption(householdSize: 1), "$10 minimum for 1 person")
        XCTAssertEqual(BudgetMath.minimumCaption(householdSize: 2), "$25 minimum for 2 people")
    }

    func testDirectBudgetInputAcceptsWholeDollars() {
        XCTAssertEqual(BudgetMath.validateInput("100", householdSize: 2), .valid(100))
    }

    func testDirectBudgetInputRoundsDecimalsToNearestDollar() {
        XCTAssertEqual(BudgetMath.validateInput("99.6", householdSize: 2), .valid(100))
        XCTAssertEqual(BudgetMath.validateInput("99,4", householdSize: 2), .valid(99))
    }

    func testDirectBudgetInputRejectsEmptyAndNonNumericText() {
        XCTAssertEqual(BudgetMath.validateInput("   ", householdSize: 2), .empty)
        XCTAssertEqual(BudgetMath.validateInput("one hundred", householdSize: 2), .notNumeric)
    }

    func testDirectBudgetInputUsesExistingHouseholdBounds() {
        XCTAssertEqual(BudgetMath.validateInput("24", householdSize: 2), .belowMinimum(25))
        XCTAssertEqual(BudgetMath.validateInput("171", householdSize: 2), .aboveMaximum(170))
        XCTAssertEqual(BudgetMath.validateInput("25", householdSize: 2), .valid(25))
        XCTAssertEqual(BudgetMath.validateInput("170", householdSize: 2), .valid(170))
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

// MARK: - Stage 1: swap / equipment / sticker / pantry matcher

final class BudgetPlanStage1Tests: XCTestCase {

    private func decode<T: Decodable>(_ json: String, as: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private let recipeJSON = """
    {"recipe_id":"r1","canonical_video_id":"budget:r1","title":"Egg Fried Rice",
     "servings":{"amount":2,"unit":null},"prep_time_minutes":null,"cook_time_minutes":15,
     "total_time_minutes":15,"ingredients":[],"instructions":[],"confidence":null,
     "source_type":"generated","image_url":null,"image_source":"none","transcript":null}
    """

    func testV10ResponseStillDecodes() throws {
        let json = """
        {"recipes":[{"recipe":\(recipeJSON),"estimated_cost":{"amount":6,"currency":"USD","basis":"x"},"health_signal":"ok"}],
         "currency":"USD","budget":75,"min_budget":50,"regional_multiplier":1.0}
        """
        let resp: BudgetPlanResponse = try decode(json)
        XCTAssertNil(resp.planId)
        XCTAssertFalse(resp.isFree)
        XCTAssertNil(resp.swapsRemaining)
        XCTAssertEqual(resp.recipes[0].equipmentUsed, [])
        XCTAssertEqual(resp.total, 6)
    }

    func testV11ResponseDecodesFreePlanFields() throws {
        let json = """
        {"recipes":[{"recipe":\(recipeJSON),"estimated_cost":{"amount":6,"currency":"USD","basis":"x"},
                     "health_signal":"ok","equipment_used":["stovetop","no_cook"]}],
         "currency":"USD","budget":75,"min_budget":50,"regional_multiplier":1.0,
         "plan_id":"p1","is_free":true,"swaps_remaining":3}
        """
        let resp: BudgetPlanResponse = try decode(json)
        XCTAssertEqual(resp.planId, "p1")
        XCTAssertTrue(resp.isFree)
        XCTAssertEqual(resp.swapsRemaining, 3)
        XCTAssertEqual(resp.recipes[0].equipmentLabels, ["Stovetop"])
    }

    func testSwapResponseDecodesNullSwapsRemainingForPro() throws {
        let json = """
        {"plan_id":"p1","meal_index":2,"meal":{"recipe":\(recipeJSON),"estimated_cost":{"amount":7,"currency":"USD","basis":"x"},"equipment_used":["oven"]},
         "plan_total":41.5,"currency":"USD","budget":75,"swaps_used":1,"swaps_remaining":null}
        """
        let resp: BudgetSwapResponse = try decode(json)
        XCTAssertEqual(resp.mealIndex, 2)
        XCTAssertEqual(resp.planTotal, 41.5)
        XCTAssertNil(resp.swapsRemaining)
        XCTAssertEqual(resp.meal.healthSignal, "")
    }

    func testNoCookRendersAsNoCookingNeverAnAppliance() {
        XCTAssertEqual(BudgetEquipment.summary(for: ["no_cook"]), "No cooking")
        XCTAssertEqual(BudgetEquipment.labels(for: ["no_cook", "oven"]), ["Oven"])
        XCTAssertEqual(BudgetEquipment.summary(for: ["stovetop", "air_fryer", "stovetop"]), "Stovetop + Air fryer")
        XCTAssertEqual(BudgetEquipment.summary(for: []), "")
    }

    // MARK: Sticker mapper

    func testStickerMapping() {
        let cases: [(String, FoodSticker)] = [
            ("Chickpea & Spinach Curry", .curry),
            ("Chicken Tikka Masala", .curry),          // curry beats chicken
            ("Beef Tacos", .tacos),
            ("Veggie Pasta Bake", .pasta),
            ("Spaghetti Carbonara", .pasta),
            ("Egg Fried Rice", .riceBowl),
            ("Chicken Ramen", .noodles),                // noodles beat chicken
            ("Sesame Peanut Noodles", .noodles),
            ("Lentil Soup", .soup),
            ("Greek Salad", .salad),
            ("Garlic Butter Shrimp", .seafood),
            ("Lemon Herb Chicken Thighs", .chicken),
            ("Shakshuka", .generic),
            ("", .generic),
        ]
        for (name, expected) in cases {
            XCTAssertEqual(FoodSticker.category(forMealName: name), expected, name)
        }
    }

    func testStickerMatchesWholeWordsOnly() {
        // "dal" must not fire inside "Randall's"; "cod" not inside "Coddled".
        XCTAssertEqual(FoodSticker.category(forMealName: "Randall's Special"), .generic)
        XCTAssertEqual(FoodSticker.category(forMealName: "Coddled Eggs"), .generic)
    }

    func testStickerAssetNames() {
        XCTAssertEqual(FoodSticker.riceBowl.assetName, "sticker_food_rice_bowl")
        XCTAssertEqual(FoodSticker.generic.assetName, "sticker_food_generic")
    }

    // MARK: Pantry matcher

    private func item(_ name: String, unit: String? = nil, qty: Double? = 1) -> GroceryLineItem {
        GroceryLineItem(name: name, quantity: qty, unit: unit, category: .other, sources: [])
    }

    func testNormalizeSingularizes() {
        XCTAssertEqual(GroceryPantryMatcher.normalize("  Eggs "), "egg")
        XCTAssertEqual(GroceryPantryMatcher.normalize("Tomatoes"), "tomato")
        XCTAssertEqual(GroceryPantryMatcher.normalize("Berries"), "berry")
        XCTAssertEqual(GroceryPantryMatcher.normalize("Hummus"), "hummus")
    }

    func testMatchIsWordBoundary() {
        XCTAssertTrue(GroceryPantryMatcher.matches(ingredient: "large eggs", pantry: "egg"))
        XCTAssertTrue(GroceryPantryMatcher.matches(ingredient: "Egg", pantry: "Eggs"))
        XCTAssertTrue(GroceryPantryMatcher.matches(ingredient: "roma tomatoes", pantry: "tomato"))
        XCTAssertFalse(GroceryPantryMatcher.matches(ingredient: "eggplant", pantry: "egg"))
        XCTAssertFalse(GroceryPantryMatcher.matches(ingredient: "licorice", pantry: "rice"))
        XCTAssertFalse(GroceryPantryMatcher.matches(ingredient: "salt", pantry: ""))
    }

    func testMultiWordPantryNeedsContiguousWords() {
        XCTAssertTrue(GroceryPantryMatcher.matches(ingredient: "extra virgin olive oil", pantry: "olive oil"))
        XCTAssertFalse(GroceryPantryMatcher.matches(ingredient: "oil for olive garnish", pantry: "olive oil"))
    }

    func testSplitMovesMatchesAndNeverDeletes() {
        let items = [item("eggs"), item("spinach"), item("eggplant"), item("tomatoes")]
        let split = GroceryPantryMatcher.split(items: items, pantryNames: ["Egg", "Tomato", "Milk"])
        XCTAssertEqual(split.inPantry.map(\.name), ["eggs", "tomatoes"])
        XCTAssertEqual(split.toBuy.map(\.name), ["spinach", "eggplant"])
        XCTAssertEqual(split.toBuy.count + split.inPantry.count, items.count)
        XCTAssertEqual(split.matchedPantryNames, ["Egg", "Tomato"])   // Milk didn't match
    }

    func testEmptyPantryMatchesNothing() {
        let split = GroceryPantryMatcher.split(items: [item("eggs")], pantryNames: [" ", ""])
        XCTAssertTrue(split.inPantry.isEmpty)
        XCTAssertEqual(split.toBuy.count, 1)
    }
}

final class BudgetPlanCardTextTests: XCTestCase {
    private func planned(prep: Double?, cook: Double?, total: Double?, equipment: [String]) -> PlannedRecipe {
        let recipe = Recipe(
            recipeId: "r", canonicalVideoId: "budget:r", title: "T",
            servings: Servings(amount: 2, unit: nil), prepTimeMinutes: prep,
            cookTimeMinutes: cook, totalTimeMinutes: total, ingredients: [], instructions: [],
            confidence: nil, sourceType: .generated, imageUrl: nil, imageSource: .none, transcript: nil
        )
        return PlannedRecipe(recipe: recipe, estimatedCost: CostEstimate(amount: 7.6), healthSignal: "", equipmentUsed: equipment)
    }

    func testCardDetailFull() {
        XCTAssertEqual(planned(prep: 10, cook: 20, total: nil, equipment: ["stovetop", "oven"]).cardDetail,
                       "$8 · 30 min · Stovetop + Oven")
    }

    func testCardDetailNoCookAndMissingTime() {
        XCTAssertEqual(planned(prep: nil, cook: nil, total: nil, equipment: ["no_cook"]).cardDetail, "$8 · No cooking")
        XCTAssertEqual(planned(prep: nil, cook: nil, total: nil, equipment: []).cardDetail, "$8")
    }

    func testTotalTimeWinsOverParts() {
        XCTAssertEqual(planned(prep: 5, cook: 5, total: 75, equipment: []).timeLabel, "1 hr 15 min")
    }
}

final class BudgetPlanPersistenceTests: XCTestCase {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "savedplan-\(UUID().uuidString)")! }

    private func plan() -> SavedBudgetPlan {
        let recipe = Recipe(
            recipeId: "r1", canonicalVideoId: "budget:r1", title: "Lentil Soup",
            servings: Servings(amount: 2, unit: nil), prepTimeMinutes: nil, cookTimeMinutes: 20,
            totalTimeMinutes: nil, ingredients: [Ingredient(quantity: 1, unit: "cup", name: "lentils", notes: nil)],
            instructions: [], confidence: nil, sourceType: .generated, imageUrl: nil, imageSource: .none, transcript: nil
        )
        return SavedBudgetPlan(
            planId: "p1",
            recipes: [PlannedRecipe(recipe: recipe, estimatedCost: CostEstimate(amount: 7), healthSignal: "hs", equipmentUsed: ["no_cook"])],
            total: 7, budget: 75, swapsRemaining: 2, isFree: true, householdSize: 3, regionLabel: "Canada"
        )
    }

    func testRoundTripPreservesEverything() {
        let d = defaults()
        let store = SavedBudgetPlanStore(defaults: d, userScope: "u1")
        XCTAssertNil(store.load())
        store.save(plan())
        let loaded = store.load()
        XCTAssertEqual(loaded?.planId, "p1")
        XCTAssertEqual(loaded?.swapsRemaining, 2)
        XCTAssertEqual(loaded?.recipes.first?.equipmentUsed, ["no_cook"])
        XCTAssertEqual(loaded?.recipes.first?.recipe.ingredients.first?.name, "lentils")
        XCTAssertEqual(loaded?.householdSize, 3)
        XCTAssertEqual(loaded?.regionLabel, "Canada")
    }

    func testPlansAreAccountScopedAndClearable() {
        let d = defaults()
        SavedBudgetPlanStore(defaults: d, userScope: "a").save(plan())
        XCTAssertNil(SavedBudgetPlanStore(defaults: d, userScope: "b").load())
        SavedBudgetPlanStore(defaults: d, userScope: "a").clear()
        XCTAssertNil(SavedBudgetPlanStore(defaults: d, userScope: "a").load())
    }

    func testProPlanNilSwapsRoundTrips() {
        let d = defaults()
        var p = plan(); p.swapsRemaining = nil; p.isFree = false
        SavedBudgetPlanStore(defaults: d).save(p)
        XCTAssertNil(SavedBudgetPlanStore(defaults: d).load()?.swapsRemaining)
    }

    func testEraserRemovesSavedPlan() {
        let d = defaults()
        SavedBudgetPlanStore(defaults: d, userScope: "u").save(plan())
        AccountDataEraser.erase(userId: "u", defaults: d)
        XCTAssertNil(SavedBudgetPlanStore(defaults: d, userScope: "u").load())
    }
}

final class MealPlanSchedulerTests: XCTestCase {
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private var start: Date { cal.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 15))! }

    func testEmptyPlanUsesConsecutiveDaysFromStart() {
        let days = MealPlanScheduler.nextOpenDays(count: 3, from: start, occupiedDinnerDayKeys: [], calendar: cal)
        XCTAssertEqual(days.map { MealPlanScheduler.dayKey(for: $0, calendar: cal) }, ["2026-09-28", "2026-09-29", "2026-09-30"])
    }

    func testSkipsDaysThatAlreadyHaveADinner() {
        let days = MealPlanScheduler.nextOpenDays(
            count: 3, from: start, occupiedDinnerDayKeys: ["2026-09-28", "2026-09-30"], calendar: cal)
        XCTAssertEqual(days.map { MealPlanScheduler.dayKey(for: $0, calendar: cal) }, ["2026-09-29", "2026-10-01", "2026-10-02"])
    }

    func testZeroCount() {
        XCTAssertTrue(MealPlanScheduler.nextOpenDays(count: 0, from: start, occupiedDinnerDayKeys: [], calendar: cal).isEmpty)
    }
}
