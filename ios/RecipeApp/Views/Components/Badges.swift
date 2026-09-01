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
struct GeneratedBadge: View {
    var body: some View {
        Label("Generated recipe", systemImage: "sparkles")
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

#Preview {
    VStack(spacing: 16) {
        GeneratedBadge()
        ImageSourceBadge(source: .videoThumbnail)
        ImageSourceBadge(source: .stockPhoto)
    }
    .padding()
}
