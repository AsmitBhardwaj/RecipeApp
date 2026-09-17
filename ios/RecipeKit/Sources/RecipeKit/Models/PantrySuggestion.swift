//
//  PantrySuggestion.swift
//  RecipeKit
//
//  Swift mirror of the backend pantry-suggestion response shapes
//  (app/pantry.py: SuggestionsResponse / Suggestion / MatchInfo). Decoded from
//  POST /v1/pantry/suggestions. Like the other model mirrors here these are
//  `Codable` with explicit snake_case `CodingKeys`, so real API JSON decodes
//  without a decoder key strategy.
//
//  The response splits results into two arrays — `matches` (found in the shared
//  recipe cache) and `generated` (freshly synthesized when cache-search came up
//  short). The client keeps them separate rather than inferring from
//  `source_type`, so the UI can label and section them independently. In
//  particular the inline "AI suggested" note is a decision of WHICH ARRAY a
//  recipe came from, made at the UI layer — there is no backend field
//  distinguishing a pantry-generated recipe from a paste-fallback generated one
//  (PANTRY_SCOPE.md §4).
//

import Foundation

// MARK: - Match info

/// Mirror of backend `MatchInfo`. `have`/`missing` are the recipe's own
/// (normalized) ingredient names split by pantry coverage, so
/// `haveCount + missing.count == totalCount`.
public struct PantryMatchInfo: Codable, Hashable {
    public let have: [String]
    public let missing: [String]
    public let haveCount: Int
    public let totalCount: Int
    public let coverage: Double
    public let score: Double

    public init(have: [String], missing: [String], haveCount: Int, totalCount: Int, coverage: Double, score: Double) {
        self.have = have
        self.missing = missing
        self.haveCount = haveCount
        self.totalCount = totalCount
        self.coverage = coverage
        self.score = score
    }

    enum CodingKeys: String, CodingKey {
        case have, missing, coverage, score
        case haveCount = "have_count"
        case totalCount = "total_count"
    }

    /// Copy for the match-context metadata line, e.g. "3/6 ingredients".
    public var ingredientSummary: String {
        "\(haveCount)/\(totalCount) ingredient\(totalCount == 1 ? "" : "s")"
    }

    /// Coverage as a whole percent (0–100) for a compact secondary label.
    public var coveragePercent: Int { Int((coverage * 100).rounded()) }
}

// MARK: - Suggestion

/// Mirror of backend `Suggestion`: a cached-or-generated recipe plus how it lines
/// up against the pantry.
public struct PantrySuggestion: Codable, Hashable, Identifiable {
    public let recipe: Recipe
    public let match: PantryMatchInfo

    public init(recipe: Recipe, match: PantryMatchInfo) {
        self.recipe = recipe
        self.match = match
    }

    public var id: String { recipe.recipeId }
}

// MARK: - Response

/// Mirror of backend `SuggestionsResponse`.
public struct PantrySuggestionsResponse: Codable, Hashable {
    /// Cache-search results, ranked (may be empty).
    public let matches: [PantrySuggestion]
    /// Generation-fallback results, present only when cache-search was sparse.
    public let generated: [PantrySuggestion]
    /// The normalized pantry the server actually matched against (for UI echo).
    public let pantryUsed: [String]
    /// {"cache": N, "generated": M}.
    public let counts: [String: Int]

    public init(matches: [PantrySuggestion], generated: [PantrySuggestion], pantryUsed: [String], counts: [String: Int]) {
        self.matches = matches
        self.generated = generated
        self.pantryUsed = pantryUsed
        self.counts = counts
    }

    enum CodingKeys: String, CodingKey {
        case matches, generated, counts
        case pantryUsed = "pantry_used"
    }

    public static let empty = PantrySuggestionsResponse(matches: [], generated: [], pantryUsed: [], counts: [:])
}
