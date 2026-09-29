//
//  BudgetPlanLibrary.swift
//  RecipeApp
//
//  Keeps a free Plan on a Budget from being lost: its recipes are saved to the
//  user's library (synced like any saved recipe) inside an auto-created "Budget
//  plan" cookbook, and swaps keep that collection in step. Built on the existing
//  library / cookbook models so everything syncs and shows in All Recipes.
//

import Foundation
import RecipeKit

@MainActor
struct BudgetPlanLibrary {
    static let cookbookName = "Budget plan"

    let jobs: PendingJobsModel
    let cookbooks: CookbooksModel
    let mealPlan: MealPlanModel

    /// Save every recipe to the library and the "Budget plan" cookbook.
    /// Idempotent: saving the same plan twice creates no duplicates.
    func savePlan(_ recipes: [Recipe]) {
        let book = cookbooks.ensureCookbook(named: Self.cookbookName)
        for recipe in recipes {
            jobs.saveToLibrary(recipe)
            if let book { cookbooks.addRecipe(recipe.recipeId, to: book.id) }
        }
    }

    /// A swap replaced `old` with `new`: add the new recipe, and drop the old one
    /// from the library and the cookbook — unless the user has since added it to
    /// the Meal Plan or to another cookbook, in which case it's left untouched.
    func replace(_ old: Recipe, with new: Recipe) {
        savePlan([new])
        let budgetBookId = cookbooks.cookbook(named: Self.cookbookName)?.id
        let inOtherCookbook = !cookbooks.cookbookIds(for: old.recipeId)
            .subtracting(budgetBookId.map { [$0] } ?? []).isEmpty
        guard !mealPlan.containsRecipe(old.recipeId), !inOtherCookbook else { return }
        cookbooks.removeRecipeFromAllCookbooks(old.recipeId)
        jobs.deleteRecipe(old)
    }
}
