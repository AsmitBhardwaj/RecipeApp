//
//  MockRecipeProvider.swift
//  RecipeApp
//
//  Hand-written sample recipes plus the mock `RecipeProvider` conformance used
//  for building and visually reviewing the UI without any network call.
//
//  The samples deliberately cover edge cases the UI must handle:
//   • `.spicyNoodles`  — full recipe, extracted from caption, real thumbnail.
//   • `.margheritaPizza`— GENERATED source + NO image_url (tests both the
//                         "generated" badge and the nil-image fallback).
//   • `.twoIngredientBagels` — very short ingredient list, stock photo.
//

import Foundation
import RecipeKit

// MARK: - Sample recipes

extension Recipe {

    /// A full, plausible extracted recipe with a real food thumbnail.
    static let spicyNoodles = Recipe(
        recipeId: "rcp_001",
        canonicalVideoId: "ig_C1a2b3c4d5",
        title: "Spicy Garlic Butter Noodles",
        servings: Servings(amount: 2, unit: nil),
        prepTimeMinutes: 10,
        cookTimeMinutes: 15,
        totalTimeMinutes: 25,
        ingredients: [
            Ingredient(quantity: 8, unit: "oz", name: "spaghetti", notes: nil),
            Ingredient(quantity: 3, unit: "tbsp", name: "unsalted butter", notes: nil),
            Ingredient(quantity: 4, unit: nil, name: "garlic cloves", notes: "minced"),
            Ingredient(quantity: 1, unit: "tbsp", name: "chili crisp", notes: "or to taste"),
            Ingredient(quantity: 2, unit: "tbsp", name: "soy sauce", notes: nil),
            Ingredient(quantity: 1, unit: "tsp", name: "sugar", notes: nil),
            Ingredient(quantity: 2, unit: nil, name: "green onions", notes: "sliced"),
            Ingredient(quantity: nil, unit: nil, name: "toasted sesame seeds", notes: "for garnish"),
        ],
        instructions: [
            Instruction(stepNumber: 1, text: "Cook the spaghetti in salted boiling water until al dente. Reserve 1/2 cup pasta water, then drain."),
            Instruction(stepNumber: 2, text: "Melt the butter in a large pan over medium heat. Add the minced garlic and cook until fragrant, about 1 minute."),
            Instruction(stepNumber: 3, text: "Stir in the chili crisp, soy sauce, and sugar. Let it bubble for 30 seconds."),
            Instruction(stepNumber: 4, text: "Add the drained noodles and toss, adding splashes of reserved pasta water until the sauce coats the noodles."),
            Instruction(stepNumber: 5, text: "Top with sliced green onions and toasted sesame seeds. Serve immediately."),
        ],
        confidence: Confidence(
            overall: 0.92,
            ingredientsComplete: true,
            instructionsComplete: true,
            missingFields: []
        ),
        sourceType: .caption,
        imageUrl: "https://images.unsplash.com/photo-1569718212165-3a8278d5f624?w=800&q=80",
        imageSource: .videoThumbnail,
        transcript: nil
    )

    /// A GENERATED recipe (fallback path) with NO image. Exercises both the
    /// generated-source badge and the missing-image graceful fallback.
    static let margheritaPizza = Recipe(
        recipeId: "rcp_002",
        canonicalVideoId: "tt_7234981726354",
        title: "Classic Margherita Pizza",
        servings: Servings(amount: 4, unit: "slices"),
        prepTimeMinutes: 20,
        cookTimeMinutes: 12,
        totalTimeMinutes: nil,
        ingredients: [
            Ingredient(quantity: 1, unit: nil, name: "pizza dough ball", notes: "store-bought or homemade"),
            Ingredient(quantity: 0.5, unit: "cup", name: "crushed San Marzano tomatoes", notes: nil),
            Ingredient(quantity: 4, unit: "oz", name: "fresh mozzarella", notes: "torn"),
            Ingredient(quantity: nil, unit: nil, name: "fresh basil leaves", notes: nil),
            Ingredient(quantity: 1, unit: "tbsp", name: "olive oil", notes: "extra virgin"),
            Ingredient(quantity: nil, unit: nil, name: "flaky salt", notes: "to taste"),
        ],
        instructions: [
            Instruction(stepNumber: 1, text: "Preheat your oven (with a pizza stone or steel if you have one) to its highest setting, ideally 500°F or higher."),
            Instruction(stepNumber: 2, text: "Stretch the dough into a 10-inch round on a floured surface."),
            Instruction(stepNumber: 3, text: "Spread the crushed tomatoes over the dough, leaving a border for the crust. Scatter the mozzarella on top."),
            Instruction(stepNumber: 4, text: "Bake until the crust is blistered and the cheese is bubbling, about 8–12 minutes."),
            Instruction(stepNumber: 5, text: "Finish with fresh basil, a drizzle of olive oil, and flaky salt."),
        ],
        confidence: Confidence(
            overall: 0.6,
            ingredientsComplete: true,
            instructionsComplete: true,
            missingFields: ["total_time_minutes"]
        ),
        sourceType: .generated,
        imageUrl: nil,
        imageSource: .none,
        transcript: nil
    )

    /// A very short, two-ingredient recipe with a stock photo.
    static let twoIngredientBagels = Recipe(
        recipeId: "rcp_003",
        canonicalVideoId: "ig_D9x8y7z6w5",
        title: "2-Ingredient Dough Bagels",
        servings: Servings(amount: 4, unit: nil),
        prepTimeMinutes: 10,
        cookTimeMinutes: 25,
        totalTimeMinutes: 35,
        ingredients: [
            Ingredient(quantity: 1, unit: "cup", name: "self-rising flour", notes: nil),
            Ingredient(quantity: 1, unit: "cup", name: "Greek yogurt", notes: "non-fat, thick"),
        ],
        instructions: [
            Instruction(stepNumber: 1, text: "Mix the flour and yogurt until a shaggy dough forms, then knead for a few minutes until smooth."),
            Instruction(stepNumber: 2, text: "Divide into 4 pieces, roll each into a rope, and pinch the ends together to form bagels."),
            Instruction(stepNumber: 3, text: "Brush with egg wash and add toppings if desired. Bake at 375°F for about 25 minutes until golden."),
        ],
        confidence: Confidence(
            overall: 0.85,
            ingredientsComplete: true,
            instructionsComplete: true,
            missingFields: []
        ),
        sourceType: .caption,
        imageUrl: "https://images.unsplash.com/photo-1585445490387-f47934b73b54?w=800&q=80",
        imageSource: .stockPhoto,
        transcript: nil
    )

    /// All samples, in list order.
    static let samples: [Recipe] = [spicyNoodles, twoIngredientBagels, margheritaPizza]
}

// MARK: - Mock provider

/// Serves the hand-written sample recipes. Kept for SwiftUI previews and offline
/// testing; the live app uses `APIRecipeProvider`. Conforms to the same
/// `RecipeProvider` contract, including `submitRecipe`.
struct MockRecipeProvider: RecipeProvider {
    func fetchRecipes() async throws -> [Recipe] {
        Recipe.samples
    }

    /// Pretends to extract: waits briefly (to exercise the UI's processing
    /// state) then returns a sample recipe. Never hits the network.
    func submitRecipe(url: String) async throws -> Recipe {
        try? await Task.sleep(for: .seconds(1))
        return .spicyNoodles
    }

    /// Enqueue a fake job — returns immediately with a `queued` status and a
    /// random id, mirroring the real POST /v1/jobs.
    func submitJob(url: String) async throws -> Job {
        Job(
            jobId: "mock_\(UUID().uuidString.prefix(8))",
            userId: "mock_user",
            url: url,
            status: .queued,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    /// Fake poll: pauses briefly so previews show a processing card, then
    /// resolves the job to `complete` with a sample recipe.
    func fetchJob(jobId: String) async throws -> JobEnvelope {
        try? await Task.sleep(for: .seconds(2))
        let job = Job(
            jobId: jobId,
            userId: "mock_user",
            url: "https://example.com",
            status: .complete,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            recipeId: Recipe.spicyNoodles.recipeId
        )
        return JobEnvelope(job: job, recipe: .spicyNoodles)
    }
}
