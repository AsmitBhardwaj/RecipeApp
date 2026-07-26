//
//  ModelDecodingTests.swift
//  RecipeKitTests
//
//  Regression guard for the model reconciliation: proves that JSON shaped like
//  the real backend `Recipe` (app/models.py) still decodes into the moved
//  RecipeKit models — including null fields and unknown keys (`nutrition`).
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
