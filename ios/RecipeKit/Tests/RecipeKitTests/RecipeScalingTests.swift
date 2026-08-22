//
//  RecipeScalingTests.swift
//  RecipeKitTests
//
//  Covers the serving-size scaling logic: fraction snapping (with the tolerance
//  fallback to decimals), scaled ingredient assembly, and the `canScaleServings`
//  gating that hides the adjuster for unscalable (e.g. structured/JSON-LD)
//  recipes.
//

import XCTest
@testable import RecipeKit

final class RecipeScalingTests: XCTestCase {

    // MARK: Fraction snapping

    func testWholeNumbersHaveNoFraction() {
        XCTAssertEqual((2.0).fractionalQuantityString(), "2")
        XCTAssertEqual((1.0).fractionalQuantityString(), "1")
    }

    func testCleanCookingFractionsSnapToGlyphs() {
        XCTAssertEqual((1.25).fractionalQuantityString(), "1\u{00BC}")  // 1¼
        XCTAssertEqual((2.5).fractionalQuantityString(), "2\u{00BD}")   // 2½
        XCTAssertEqual((3.75).fractionalQuantityString(), "3\u{00BE}")  // 3¾
        XCTAssertEqual((0.625).fractionalQuantityString(), "\u{215D}")  // ⅝
        XCTAssertEqual((1.0 / 3.0).fractionalQuantityString(), "\u{2153}") // ⅓
    }

    func testFractionalPartNearWholeRoundsUp() {
        // 0.97 is within tolerance of 1 → carries to the whole number.
        XCTAssertEqual((1.97).fractionalQuantityString(), "2")
        // 2.02 is within tolerance of 2 → drops the fraction.
        XCTAssertEqual((2.02).fractionalQuantityString(), "2")
    }

    func testUnresolvableRatioFallsBackToDecimal() {
        // 0.1875 sits between ⅛ and ¼, farther than the default 0.05 tolerance
        // from either — so it must NOT invent a fraction; it shows a decimal.
        XCTAssertEqual((0.1875).fractionalQuantityString(), "0.2")
    }

    func testToleranceIsHonored() {
        // 0.4375 sits midway (0.0625) between ⅜ and ½ — outside the default 0.05
        // window (so it falls back to a decimal), but inside a widened one (so it
        // snaps). This pins the tolerance's effect without tripping the
        // snap-to-whole threshold that also keys off `tolerance`.
        XCTAssertEqual((0.4375).fractionalQuantityString(), "0.4")
        let snapped = (0.4375).fractionalQuantityString(tolerance: 0.07)
        XCTAssertTrue(snapped == "\u{215C}" || snapped == "\u{00BD}",  // ⅜ or ½
                      "expected a snapped fraction, got \(snapped)")
    }

    // MARK: Scaled ingredient assembly

    func testScaledIngredientMultipliesQuantity() {
        let ing = Ingredient(quantity: 1, unit: "cup", name: "flour", notes: nil)
        // base 4 -> 5 servings = 1.25x
        XCTAssertEqual(ing.displayString(scaledBy: 1.25), "1\u{00BC} cup flour")
    }

    func testScaledIngredientPreservesNotes() {
        let ing = Ingredient(quantity: 2, unit: "tbsp", name: "olive oil", notes: "extra virgin")
        XCTAssertEqual(ing.displayString(scaledBy: 1.25), "2\u{00BD} tbsp olive oil (extra virgin)")
    }

    func testIngredientWithoutQuantityIsUnchangedByScaling() {
        // The structured/JSON-LD shape: whole line in `name`, no numeric quantity.
        let ing = Ingredient(quantity: nil, unit: nil, name: "2 cups all-purpose flour", notes: nil)
        XCTAssertEqual(ing.displayString(scaledBy: 2.0), ing.displayString)
        XCTAssertEqual(ing.displayString(scaledBy: 2.0), "2 cups all-purpose flour")
    }

    // MARK: Gating

    func testCanScaleWhenBaseAndNumericQuantityPresent() {
        let recipe = makeRecipe(
            servings: Servings(amount: 4, unit: nil),
            ingredients: [Ingredient(quantity: 1, unit: "cup", name: "flour", notes: nil)]
        )
        XCTAssertEqual(recipe.baseServings, 4)
        XCTAssertTrue(recipe.canScaleServings)
    }

    func testCannotScaleWithoutNumericBaseServings() {
        let recipe = makeRecipe(
            servings: Servings(amount: nil, unit: "loaf"),
            ingredients: [Ingredient(quantity: 1, unit: "cup", name: "flour", notes: nil)]
        )
        XCTAssertNil(recipe.baseServings)
        XCTAssertFalse(recipe.canScaleServings)
    }

    func testCannotScaleStructuredRecipeEvenWithNumericBase() {
        // recipeYield gave us a base of 4, but every ingredient is unparsed text
        // with no numeric quantity → adjuster must stay hidden.
        let recipe = makeRecipe(
            servings: Servings(amount: 4, unit: nil),
            ingredients: [
                Ingredient(quantity: nil, unit: nil, name: "2 cups flour", notes: nil),
                Ingredient(quantity: nil, unit: nil, name: "1 tsp salt", notes: nil),
            ]
        )
        XCTAssertEqual(recipe.baseServings, 4)
        XCTAssertFalse(recipe.canScaleServings)
    }

    // MARK: Helpers

    private func makeRecipe(servings: Servings, ingredients: [Ingredient]) -> Recipe {
        Recipe(
            recipeId: "r", canonicalVideoId: "v", title: "t",
            servings: servings,
            prepTimeMinutes: nil, cookTimeMinutes: nil, totalTimeMinutes: nil,
            ingredients: ingredients, instructions: [],
            confidence: nil, sourceType: .caption,
            imageUrl: nil, imageSource: .none, transcript: nil
        )
    }
}
