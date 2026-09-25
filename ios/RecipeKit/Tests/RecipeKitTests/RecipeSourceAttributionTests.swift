import XCTest
@testable import RecipeKit

final class RecipeSourceAttributionTests: XCTestCase {
    private func recipe(url: String?, platform: String?, creator: String?) -> Recipe {
        Recipe(
            recipeId: "r", canonicalVideoId: "v", title: "Soup",
            servings: Servings(amount: nil, unit: nil),
            prepTimeMinutes: nil, cookTimeMinutes: nil, totalTimeMinutes: nil,
            ingredients: [], instructions: [], confidence: nil,
            sourceType: .caption, imageUrl: nil, imageSource: .none,
            transcript: nil, sourceUrl: url, sourcePlatform: platform,
            sourceCreator: creator
        )
    }

    func testSocialCreatorLabel() throws {
        let value = try XCTUnwrap(recipe(
            url: "https://www.instagram.com/reel/abc/",
            platform: "instagram",
            creator: "chef"
        ).sourceAttribution)
        XCTAssertEqual(value.label, "Source: @chef on Instagram")
    }

    func testWebFallsBackToHostnameWithoutCreator() throws {
        let value = try XCTUnwrap(recipe(
            url: "https://www.example.com/recipes/soup",
            platform: "web",
            creator: nil
        ).sourceAttribution)
        XCTAssertEqual(value.label, "Source: example.com")
    }

    func testUnsafeOrMissingURLIsNotTappable() {
        XCTAssertNil(recipe(url: nil, platform: "web", creator: nil).sourceAttribution)
        XCTAssertNil(recipe(url: "javascript:alert(1)", platform: "web", creator: nil).sourceAttribution)
    }
}
