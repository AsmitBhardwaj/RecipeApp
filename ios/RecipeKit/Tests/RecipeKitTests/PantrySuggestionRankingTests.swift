//
//  PantrySuggestionRankingTests.swift
//  RecipeKitTests
//
//  Covers PantrySuggestionRanking: coverage-ratio sort, matched-count tie-break,
//  and the "drop < 20% unless it leaves fewer than 3" filter.
//

import XCTest
@testable import RecipeKit

final class PantrySuggestionRankingTests: XCTestCase {

    // MARK: - Fixtures

    private func suggestion(_ id: String, have: Int, total: Int) -> PantrySuggestion {
        let recipe = Recipe(
            recipeId: id,
            canonicalVideoId: "v_\(id)",
            title: id,
            servings: Servings(amount: nil, unit: nil),
            prepTimeMinutes: nil,
            cookTimeMinutes: nil,
            totalTimeMinutes: nil,
            ingredients: [],
            instructions: [],
            confidence: nil,
            sourceType: .caption,
            imageUrl: nil,
            imageSource: .none,
            transcript: nil
        )
        let match = PantryMatchInfo(
            have: [], missing: [],
            haveCount: have, totalCount: total,
            coverage: total > 0 ? Double(have) / Double(total) : 0,
            score: 0
        )
        return PantrySuggestion(recipe: recipe, match: match)
    }

    private func ids(_ suggestions: [PantrySuggestion]) -> [String] {
        suggestions.map { $0.recipe.recipeId }
    }

    // MARK: - Sorting

    func testSortsByCoverageRatioDescending() {
        let result = PantrySuggestionRanking.rank([
            suggestion("a", have: 5, total: 10),  // 0.50
            suggestion("b", have: 8, total: 10),  // 0.80
            suggestion("c", have: 3, total: 10),  // 0.30
        ])
        XCTAssertEqual(ids(result), ["b", "a", "c"])
    }

    func testTieBreaksByMatchedCountDescending() {
        // Same 0.50 ratio; higher matched count ranks first.
        let result = PantrySuggestionRanking.rank([
            suggestion("few", have: 2, total: 4),   // 0.50, matched 2
            suggestion("many", have: 4, total: 8),  // 0.50, matched 4
        ])
        XCTAssertEqual(ids(result), ["many", "few"])
    }

    func testTieBreakIsDeterministicByRecipeId() {
        // Identical ratio AND matched count → stable order by recipe id.
        let result = PantrySuggestionRanking.rank([
            suggestion("z", have: 1, total: 2),
            suggestion("a", have: 1, total: 2),
        ])
        XCTAssertEqual(ids(result), ["a", "z"])
    }

    // MARK: - Filtering

    func testExcludesBelowTwentyPercentWhenAtLeastThreeRemain() {
        let result = PantrySuggestionRanking.rank([
            suggestion("a", have: 5, total: 10),   // 0.50 keep
            suggestion("b", have: 3, total: 10),   // 0.30 keep
            suggestion("c", have: 2, total: 8),    // 0.25 keep
            suggestion("d", have: 2, total: 20),   // 0.10 drop
            suggestion("e", have: 1, total: 20),   // 0.05 drop
        ])
        XCTAssertEqual(ids(result), ["a", "b", "c"])
        XCTAssertFalse(ids(result).contains("d"))
        XCTAssertFalse(ids(result).contains("e"))
    }

    func testKeepsTopThreeWhenFilteringWouldLeaveFewer() {
        // Only "a" clears 20%; rather than return 1, keep the top 3 by rank.
        let result = PantrySuggestionRanking.rank([
            suggestion("a", have: 5, total: 10),   // 0.50 qualifies
            suggestion("b", have: 1, total: 10),   // 0.10
            suggestion("c", have: 1, total: 10),   // 0.10
            suggestion("d", have: 0, total: 10),   // 0.00
        ])
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(ids(result), ["a", "b", "c"])  // b,c tie → recipe id
        XCTAssertFalse(ids(result).contains("d"))
    }

    func testReturnsAllWhenFewerThanThreeTotal() {
        let result = PantrySuggestionRanking.rank([
            suggestion("a", have: 5, total: 10),   // 0.50
            suggestion("b", have: 1, total: 20),   // 0.05
        ])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(ids(result), ["a", "b"])
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertTrue(PantrySuggestionRanking.rank([]).isEmpty)
    }
}
