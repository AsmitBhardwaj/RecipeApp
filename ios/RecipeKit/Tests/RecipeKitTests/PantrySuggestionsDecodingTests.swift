//
//  PantrySuggestionsDecodingTests.swift
//  RecipeKitTests
//
//  Regression guard for the pantry-suggestion wire mapping: proves JSON shaped
//  like the real backend POST /v1/pantry/suggestions response (app/pantry.py:
//  SuggestionsResponse) decodes into the RecipeKit models, including the
//  snake_case match fields and the matches/generated split.
//

import XCTest
@testable import RecipeKit

final class PantrySuggestionsDecodingTests: XCTestCase {

    private let backendJSON = """
    {
      "matches": [
        {
          "recipe": {
            "recipe_id": "rcp_1",
            "canonical_video_id": "ig_1",
            "title": "Spaghetti Carbonara",
            "servings": { "amount": 2, "unit": null },
            "prep_time_minutes": null,
            "cook_time_minutes": null,
            "total_time_minutes": null,
            "ingredients": [
              { "quantity": null, "unit": null, "name": "egg", "notes": null }
            ],
            "instructions": [],
            "confidence": { "overall": 0.8, "ingredients_complete": true, "instructions_complete": true, "missing_fields": [] },
            "source_type": "caption",
            "image_url": null,
            "image_source": "none",
            "transcript": null,
            "nutrition": null
          },
          "match": {
            "have": ["egg", "spaghetti", "bacon"],
            "missing": ["parmesan", "black pepper"],
            "have_count": 3,
            "total_count": 5,
            "coverage": 0.6,
            "score": 0.71
          }
        }
      ],
      "generated": [
        {
          "recipe": {
            "recipe_id": "rcp_gen",
            "canonical_video_id": "pantry-gen:egg-fried-rice",
            "title": "Egg Fried Rice",
            "servings": { "amount": 2, "unit": "servings" },
            "prep_time_minutes": null,
            "cook_time_minutes": null,
            "total_time_minutes": null,
            "ingredients": [
              { "quantity": null, "unit": null, "name": "egg", "notes": null }
            ],
            "instructions": [{ "step_number": 1, "text": "Fry it." }],
            "confidence": { "overall": 0.6, "ingredients_complete": true, "instructions_complete": true, "missing_fields": [] },
            "source_type": "generated",
            "image_url": null,
            "image_source": "none",
            "transcript": null,
            "nutrition": null
          },
          "match": {
            "have": ["egg", "rice"],
            "missing": [],
            "have_count": 2,
            "total_count": 2,
            "coverage": 1.0,
            "score": 0.9
          }
        }
      ],
      "pantry_used": ["egg", "spaghetti", "bacon", "rice"],
      "counts": { "cache": 1, "generated": 1 }
    }
    """

    func testDecodesResponseWithMatchesAndGenerated() throws {
        let data = Data(backendJSON.utf8)
        let response = try JSONDecoder().decode(PantrySuggestionsResponse.self, from: data)

        XCTAssertEqual(response.matches.count, 1)
        XCTAssertEqual(response.generated.count, 1)
        XCTAssertEqual(response.pantryUsed, ["egg", "spaghetti", "bacon", "rice"])
        XCTAssertEqual(response.counts["cache"], 1)
        XCTAssertEqual(response.counts["generated"], 1)

        let match = response.matches[0].match
        XCTAssertEqual(match.haveCount, 3)
        XCTAssertEqual(match.totalCount, 5)
        XCTAssertEqual(match.coverage, 0.6, accuracy: 0.0001)
        XCTAssertEqual(match.have.count + match.missing.count, match.totalCount)
        XCTAssertEqual(match.ingredientSummary, "3/5 ingredients")

        // The generated array carries the generated recipe (which the UI marks
        // with an inline "AI suggested" note); cache matches do not.
        XCTAssertTrue(response.generated[0].recipe.isGenerated)
        XCTAssertFalse(response.matches[0].recipe.isGenerated)
        // Suggestion.id proxies the recipe id (Identifiable for ForEach).
        XCTAssertEqual(response.generated[0].id, "rcp_gen")
    }

    func testSingularIngredientSummary() {
        let m = PantryMatchInfo(have: ["egg"], missing: [], haveCount: 1, totalCount: 1, coverage: 1.0, score: 0.5)
        XCTAssertEqual(m.ingredientSummary, "1/1 ingredient")
    }
}
