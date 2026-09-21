//
//  PantrySuggestionRanking.swift
//  RecipeKit
//
//  Client-side ordering for the pantry "Cook with what you have" matches. The
//  backend returns matches already scored, but the UI applies this deterministic
//  rank on top so the surface stays consistent regardless of server-side tuning:
//
//   • sort by coverage ratio (matched / total) descending,
//   • tie-break by matched count descending (then recipe id, for stability),
//   • drop matches below 20% coverage — UNLESS doing so would leave fewer than
//     three results, in which case the top-ranked results are kept to reach three
//     (or all of them, when fewer than three exist).
//
//  Pure and side-effect free so it can be unit-tested without any UI or network.
//

import Foundation

public enum PantrySuggestionRanking {

    /// Minimum coverage a match needs to survive filtering (20%).
    public static let minimumCoverage: Double = 0.20
    /// Never trim below this many results, even if it means keeping sub-threshold
    /// matches.
    public static let minimumResults: Int = 3

    /// Coverage ratio for one match: matched / total (0 when total is 0).
    public static func coverageRatio(_ match: PantryMatchInfo) -> Double {
        guard match.totalCount > 0 else { return 0 }
        return Double(match.haveCount) / Double(match.totalCount)
    }

    /// Rank and filter cache matches per the rules above.
    public static func rank(_ suggestions: [PantrySuggestion]) -> [PantrySuggestion] {
        let sorted = suggestions.sorted { lhs, rhs in
            let lr = coverageRatio(lhs.match)
            let rr = coverageRatio(rhs.match)
            if lr != rr { return lr > rr }
            if lhs.match.haveCount != rhs.match.haveCount {
                return lhs.match.haveCount > rhs.match.haveCount
            }
            // Final, stable tie-break so ordering is deterministic.
            return lhs.recipe.recipeId < rhs.recipe.recipeId
        }

        let qualified = sorted.filter { coverageRatio($0.match) >= minimumCoverage }
        if qualified.count >= minimumResults {
            return qualified
        }
        // Filtering would leave fewer than three — keep the top-ranked results up
        // to three (or all of them, if there are fewer than three in total).
        return Array(sorted.prefix(minimumResults))
    }
}
