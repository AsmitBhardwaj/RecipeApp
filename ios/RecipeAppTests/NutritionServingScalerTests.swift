//
//  NutritionServingScalerTests.swift
//  RecipeAppTests
//
//  RecipeDetailView 1.1: the servings stepper (`ServingScaler`) must never move
//  the nutrition card's numbers — only `Recipe.baseServings` (the ORIGINAL
//  serving count) feeds `Nutrition.perServingDisplay`, never
//  `ServingScaler.currentServings`. These tests drive the real `ServingScaler`
//  the stepper uses and confirm the resolved nutrition display is identical no
//  matter where the user has moved the stepper.
//

import XCTest
@testable import RecipeApp
import RecipeKit

@MainActor
final class NutritionServingScalerTests: XCTestCase {

    private func makeRecipe(baseServings: Double, nutrition: Nutrition) -> Recipe {
        Recipe(
            recipeId: "r1", canonicalVideoId: "v1", title: "Test",
            servings: Servings(amount: baseServings, unit: nil),
            prepTimeMinutes: nil, cookTimeMinutes: nil, totalTimeMinutes: nil,
            ingredients: [Ingredient(quantity: 1, unit: "cup", name: "flour", notes: nil)],
            instructions: [], confidence: nil, sourceType: .caption,
            imageUrl: nil, imageSource: .none, transcript: nil, nutrition: nutrition
        )
    }

    func testIncrementingTheStepperDoesNotChangePerRecipeNutrition() {
        // 900 kcal whole recipe / 4 original servings = 225/serving.
        let nutrition = Nutrition(calories: 900, proteinG: 32, carbsG: 96, fatG: 40, basis: .perRecipe, source: .estimated)
        let recipe = makeRecipe(baseServings: 4, nutrition: nutrition)
        let scaler = ServingScaler(baseServings: recipe.baseServings ?? 1)

        let before = nutrition.perServingDisplay(originalServings: recipe.baseServings)
        XCTAssertEqual(before.calories, 225)

        scaler.increment()
        scaler.increment()
        scaler.increment()
        XCTAssertEqual(scaler.currentServings, 7, "sanity: the stepper itself did move")

        let after = nutrition.perServingDisplay(originalServings: recipe.baseServings)
        XCTAssertEqual(after, before, "nutrition must read Recipe.baseServings, never the live scaler state")
        XCTAssertEqual(after.calories, 225)
    }

    func testDecrementingBelowBaseDoesNotChangePerServingNutrition() {
        let nutrition = Nutrition(calories: 373, proteinG: 24, carbsG: 37, fatG: 12, basis: .perServing, source: .estimated)
        let recipe = makeRecipe(baseServings: 4, nutrition: nutrition)
        let scaler = ServingScaler(baseServings: recipe.baseServings ?? 1)

        let before = nutrition.perServingDisplay(originalServings: recipe.baseServings)

        scaler.decrement()
        scaler.decrement()
        XCTAssertEqual(scaler.currentServings, 2)

        let after = nutrition.perServingDisplay(originalServings: recipe.baseServings)
        XCTAssertEqual(after, before)
        XCTAssertEqual(after.calories, 373, "per_serving nutrition is already per serving — scaling servings must not touch it")
    }
}
