//
//  ModelDecodingTests.swift
//  RecipeKitTests
//
//  Regression guard for the model reconciliation: proves that JSON shaped like
//  the real backend `Recipe` (app/models.py) still decodes into the moved
//  RecipeKit models — including null fields, and the `nutrition` object (present,
//  partial, or null on recipes cached before nutrition shipped).
//

import XCTest
@testable import RecipeKit

final class ModelDecodingTests: XCTestCase {

    /// Mirrors a real backend payload: snake_case keys, nulls in optional fields,
    /// and the `nutrition` key the Swift model intentionally ignores.
    private let backendJSON = """
    {
      "recipe_id": "rcp_abc",
      "canonical_video_id": "ig_XYZ",
      "title": "Test Dish",
      "servings": { "amount": 2, "unit": null },
      "prep_time_minutes": 10,
      "cook_time_minutes": null,
      "total_time_minutes": null,
      "ingredients": [
        { "quantity": 1, "unit": "cup", "name": "flour", "notes": null },
        { "quantity": null, "unit": null, "name": "salt", "notes": "to taste" }
      ],
      "instructions": [
        { "step_number": 1, "text": "Mix." }
      ],
      "confidence": {
        "overall": 0.8,
        "ingredients_complete": true,
        "instructions_complete": false,
        "missing_fields": ["cook_time_minutes"]
      },
      "source_type": "caption",
      "image_url": null,
      "image_source": "none",
      "transcript": null,
      "nutrition": null
    }
    """

    func testDecodesRealisticBackendPayload() throws {
        let recipe = try JSONDecoder().decode(Recipe.self, from: Data(backendJSON.utf8))

        XCTAssertEqual(recipe.recipeId, "rcp_abc")
        XCTAssertEqual(recipe.canonicalVideoId, "ig_XYZ")
        XCTAssertEqual(recipe.servings.amount, 2)
        XCTAssertNil(recipe.servings.unit)
        XCTAssertNil(recipe.cookTimeMinutes)
        XCTAssertNil(recipe.imageUrl)
        XCTAssertEqual(recipe.imageSource, ImageSource.none)
        XCTAssertEqual(recipe.sourceType, .caption)
        XCTAssertEqual(recipe.ingredients.count, 2)
        XCTAssertEqual(recipe.ingredients[1].name, "salt")
        XCTAssertEqual(recipe.ingredients[1].notes, "to taste")
        XCTAssertEqual(recipe.confidence?.missingFields, ["cook_time_minutes"])
        // A recipe cached before nutrition shipped (nutrition: null) decodes with
        // no nutrition — the no-migration guarantee.
        XCTAssertNil(recipe.nutrition)
    }

    /// A recipe WITH nutrition decodes fully, including snake_case macro keys and
    /// the basis/source markers; a nil macro stays nil rather than becoming zero.
    func testDecodesNutritionWhenPresent() throws {
        let json = """
        { "recipe_id": "r", "canonical_video_id": "v", "title": "t",
          "servings": {"amount": 2, "unit": null},
          "prep_time_minutes": null, "cook_time_minutes": null, "total_time_minutes": null,
          "ingredients": [], "instructions": [], "confidence": null,
          "source_type": "caption", "image_url": null, "image_source": "none",
          "transcript": null,
          "nutrition": { "calories": 380, "protein_g": 38, "carbs_g": null, "fat_g": 22,
                         "basis": "per_serving", "source": "creator_stated" } }
        """
        let recipe = try JSONDecoder().decode(Recipe.self, from: Data(json.utf8))
        let n = try XCTUnwrap(recipe.nutrition)
        XCTAssertEqual(n.calories, 380)
        XCTAssertEqual(n.proteinG, 38)
        XCTAssertNil(n.carbsG, "a nil macro stays nil, not 0")
        XCTAssertEqual(n.fatG, 22)
        XCTAssertEqual(n.basis, .perServing)
        XCTAssertEqual(n.source, .creatorStated)
    }

    /// Unknown basis/source values decode defensively to the conservative default.
    func testUnknownNutritionEnumsDecodeToDefaults() throws {
        let json = """
        { "calories": 100, "protein_g": null, "carbs_g": null, "fat_g": null,
          "basis": "per_week", "source": "vibes" }
        """
        let n = try JSONDecoder().decode(Nutrition.self, from: Data(json.utf8))
        XCTAssertEqual(n.basis, .perRecipe, "unknown basis falls back to .perRecipe")
        XCTAssertEqual(n.source, .estimated, "unknown source falls back to .estimated")
    }

    /// Unknown enum values must decode defensively instead of throwing.
    func testUnknownEnumValuesDecodeToDefaults() throws {
        let json = """
        { "recipe_id": "r", "canonical_video_id": "v", "title": "t",
          "servings": {"amount": null, "unit": null},
          "prep_time_minutes": null, "cook_time_minutes": null, "total_time_minutes": null,
          "ingredients": [], "instructions": [], "confidence": null,
          "source_type": "something_new", "image_url": null, "image_source": "future_source",
          "transcript": null }
        """
        let recipe = try JSONDecoder().decode(Recipe.self, from: Data(json.utf8))
        XCTAssertEqual(recipe.sourceType, .caption, "unknown source_type falls back to .caption")
        XCTAssertEqual(recipe.imageSource, ImageSource.none, "unknown image_source falls back to .none")
    }
}
