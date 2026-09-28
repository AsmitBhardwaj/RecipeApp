//
//  NutritionDisplayTests.swift
//  RecipeKitTests
//
//  Coverage for NutritionDisplay.swift — the pure math behind the recipe-detail
//  nutrition card: always-per-serving values regardless of `basis`, and
//  calorie-share percentages for the donut ring legend.
//

import XCTest
@testable import RecipeKit

final class NutritionDisplayTests: XCTestCase {

    // MARK: perServingDisplay

    func testPerServingBasisPassesValuesThroughUnchanged() {
        let n = Nutrition(calories: 373, proteinG: 24, carbsG: 37, fatG: 12, basis: .perServing, source: .estimated)
        let display = n.perServingDisplay(originalServings: 4)
        XCTAssertEqual(display.calories, 373, "per_serving values are already per serving — the servings count is ignored")
        XCTAssertEqual(display.proteinG, 24)
        XCTAssertEqual(display.carbsG, 37)
        XCTAssertEqual(display.fatG, 12)
        XCTAssertEqual(display.captionPrefix, "Per serving")
    }

    func testPerRecipeDividesByOriginalServingsAndRounds() {
        // 900 kcal / 4 servings = 225; 33g protein / 4 = 8.25 → rounds to 8.
        let n = Nutrition(calories: 900, proteinG: 33, carbsG: 96, fatG: 40, basis: .perRecipe, source: .creatorStated)
        let display = n.perServingDisplay(originalServings: 4)
        XCTAssertEqual(display.calories, 225)
        XCTAssertEqual(display.proteinG, 8, "8.25 rounds down to 8")
        XCTAssertEqual(display.carbsG, 24)
        XCTAssertEqual(display.fatG, 10)
        XCTAssertEqual(display.captionPrefix, "Per serving")
    }

    func testPerRecipeRoundsAwayFromZeroAtTheHalfway() {
        // 101 / 4 = 25.25 → 25; 102 / 4 = 25.5 → 26 (round half away from zero).
        let n = Nutrition(calories: 102, proteinG: nil, carbsG: nil, fatG: nil, basis: .perRecipe, source: .estimated)
        XCTAssertEqual(n.perServingDisplay(originalServings: 4).calories, 26)
    }

    func testPerRecipeWithNilOriginalServingsFallsBackToWholeRecipe() {
        let n = Nutrition(calories: 900, proteinG: 33, carbsG: 96, fatG: 40, basis: .perRecipe, source: .estimated)
        let display = n.perServingDisplay(originalServings: nil)
        XCTAssertEqual(display.calories, 900, "no known base serving count — show the whole-recipe total, not a wrong division")
        XCTAssertEqual(display.proteinG, 33)
        XCTAssertEqual(display.captionPrefix, "Whole recipe", "caption must not claim per-serving when it isn't")
    }

    func testPerRecipeWithZeroOriginalServingsFallsBackToWholeRecipe() {
        let n = Nutrition(calories: 900, proteinG: nil, carbsG: nil, fatG: nil, basis: .perRecipe, source: .estimated)
        let display = n.perServingDisplay(originalServings: 0)
        XCTAssertEqual(display.calories, 900, "a zero/invalid servings count must not divide by zero")
        XCTAssertEqual(display.captionPrefix, "Whole recipe")
    }

    func testNilMacroStaysNilThroughDivision() {
        let n = Nutrition(calories: 900, proteinG: nil, carbsG: 96, fatG: nil, basis: .perRecipe, source: .estimated)
        let display = n.perServingDisplay(originalServings: 4)
        XCTAssertNil(display.proteinG, "a macro the estimate left nil must stay nil, not become 0")
        XCTAssertNil(display.fatG)
        XCTAssertEqual(display.carbsG, 24)
    }

    func testSourceCaption() {
        XCTAssertEqual(Nutrition(calories: 1, proteinG: nil, carbsG: nil, fatG: nil, basis: .perServing, source: .estimated).sourceCaption, "Estimated")
        XCTAssertEqual(Nutrition(calories: 1, proteinG: nil, carbsG: nil, fatG: nil, basis: .perServing, source: .creatorStated).sourceCaption, "From creator")
    }

    // MARK: calorieShare

    func testCalorieSharePercentagesSumToOneHundred() {
        // protein 24g×4=96, carbs 37g×4=148, fat 12g×9=108 → total 352.
        let n = Nutrition(calories: 373, proteinG: 24, carbsG: 37, fatG: 12, basis: .perServing, source: .estimated)
        let share = try! XCTUnwrap(n.calorieShare)
        XCTAssertEqual(share.proteinPercent + share.carbsPercent + share.fatPercent, 100)
        XCTAssertEqual(share.proteinPercent, 27)
        XCTAssertEqual(share.carbsPercent, 42)
        XCTAssertEqual(share.fatPercent, 31)
    }

    func testCalorieShareStillSumsTo100AcrossManyMacroCombinations() {
        // A spread of gram combinations, including ones whose raw percentages
        // land exactly on awkward rounding boundaries — every one must still
        // sum to exactly 100 (largest-remainder, not independent rounding).
        let cases: [(Double, Double, Double)] = [
            (1, 1, 1), (10, 10, 10), (24, 37, 12), (1, 0, 0), (0, 1, 0),
            (7, 13, 5), (33, 96, 40), (100, 1, 1), (17, 17, 17), (2, 3, 5),
        ]
        for (p, c, f) in cases {
            let n = Nutrition(calories: nil, proteinG: p, carbsG: c, fatG: f, basis: .perServing, source: .estimated)
            let share = try! XCTUnwrap(n.calorieShare, "p=\(p) c=\(c) f=\(f)")
            XCTAssertEqual(share.proteinPercent + share.carbsPercent + share.fatPercent, 100, "p=\(p) c=\(c) f=\(f)")
        }
    }

    func testCalorieShareIsNilWhenNoMacroContributesCalories() {
        let n = Nutrition(calories: 100, proteinG: nil, carbsG: nil, fatG: nil, basis: .perServing, source: .estimated)
        XCTAssertNil(n.calorieShare)
    }

    func testCalorieShareIsScaleInvariant() {
        // Same ratio whether the grams are whole-recipe or per-serving totals —
        // the share must not depend on `originalServings`.
        let wholeRecipe = Nutrition(calories: 900, proteinG: 32, carbsG: 96, fatG: 40, basis: .perRecipe, source: .estimated)
        let perServing = Nutrition(calories: 225, proteinG: 8, carbsG: 24, fatG: 10, basis: .perServing, source: .estimated)
        let a = try! XCTUnwrap(wholeRecipe.calorieShare)
        let b = try! XCTUnwrap(perServing.calorieShare)
        XCTAssertEqual(a.proteinPercent, b.proteinPercent)
        XCTAssertEqual(a.carbsPercent, b.carbsPercent)
        XCTAssertEqual(a.fatPercent, b.fatPercent)
    }
}
