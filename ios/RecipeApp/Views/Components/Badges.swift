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
            .padding(.vertical, 5)
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
