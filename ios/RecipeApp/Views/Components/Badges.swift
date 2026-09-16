//
//  Badges.swift
//  RecipeApp
//
//  Small pill badges. `GeneratedBadge` satisfies the CLAUDE.md §5 hard rule
//  that a generated recipe must be visually distinguishable from an extracted
//  one. `ImageSourceBadge` shows image provenance so a stock photo is never
//  mistaken for the creator's actual dish.
//

import SwiftUI
import RecipeKit

/// Marks a `source_type: "generated"` recipe. Distinct accent + icon.
///
/// `label` is caller-supplied so the SAME badge serves different trust contexts
/// without a backend flag to tell them apart: the pantry-suggestions surface
/// renders it as "Suggested recipe", while its default keeps the original
/// "Generated recipe" wording. The paste-fallback list/detail deliberately don't
/// render it at all (CLAUDE.md §5) — reviving it is scoped to the surfaces that
/// opt in, i.e. pass this view (PANTRY_SCOPE.md §4).
struct GeneratedBadge: View {
    var label: String = "Generated recipe"

    var body: some View {
        Label(label, systemImage: "sparkles")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            // Match the duration pill's vertical padding (3) so the badge is the
            // same compact height and hugs the pill above it, instead of adding a
            // taller capsule that reads as excess spacing on generated-recipe cards.
            .padding(.vertical, 3)
            .foregroundStyle(Color.badgeGenerated)
            .background(Color.badgeGenerated.opacity(0.15), in: Capsule())
    }
}

/// Shows where a recipe's image came from ("From video" / "Stock photo").
struct ImageSourceBadge: View {
    let source: ImageSource

    var body: some View {
        if let label = source.badgeLabel {
            Label(label, systemImage: icon)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .foregroundStyle(.white)
                .background(.black.opacity(0.55), in: Capsule())
        }
    }

    private var icon: String {
        switch source {
        case .videoThumbnail: return "video.fill"
        case .stockPhoto: return "photo.fill"
        case .webImage: return "globe"
        case .none: return "photo"
        }
    }
}

/// Pantry-match context for a suggested recipe, e.g. "3 of 6 ingredients". Muted,
/// neutral styling — it's an informational chip, not a trust signal like
/// `GeneratedBadge`. Reads the `PantryMatchInfo` the suggestions API returns.
struct MatchContextBadge: View {
    let match: PantryMatchInfo

    var body: some View {
        Label(match.ingredientSummary, systemImage: "checklist")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(Color.textSecondary)
            .background(Color.textSecondary.opacity(0.12), in: Capsule())
    }
}

#Preview {
    VStack(spacing: 16) {
        GeneratedBadge()
        GeneratedBadge(label: "Suggested recipe")
        MatchContextBadge(match: PantryMatchInfo(
            have: ["egg", "spaghetti", "bacon"], missing: ["parmesan", "black pepper"],
            haveCount: 3, totalCount: 5, coverage: 0.6, score: 0.71
        ))
        ImageSourceBadge(source: .videoThumbnail)
        ImageSourceBadge(source: .stockPhoto)
    }
    .padding()
}
