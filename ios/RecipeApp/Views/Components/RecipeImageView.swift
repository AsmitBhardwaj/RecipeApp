//
//  RecipeImageView.swift
//  RecipeApp
//
//  Loads a recipe image with graceful fallbacks. When `imageUrl` is nil, the
//  URL is malformed, or the load fails, it shows a tasteful placeholder rather
//  than a broken-image icon or a crash (CLAUDE.md: never show a broken image).
//

import SwiftUI

struct RecipeImageView: View {
    let imageUrl: String?
    /// Point size for the placeholder glyph, scaled to the usage site.
    var placeholderSymbolSize: CGFloat = 34

    var body: some View {
        if let imageUrl, let url = URL(string: imageUrl) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure:
                    placeholder
                case .empty:
                    ZStack {
                        placeholderBackground
                        ProgressView()
                    }
                @unknown default:
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            placeholderBackground
            Image(systemName: "fork.knife")
                .font(.system(size: placeholderSymbolSize, weight: .light))
                .foregroundStyle(.secondary)
        }
    }

    private var placeholderBackground: some View {
        Rectangle()
            .fill(.quaternary)
    }
}

#Preview("With image") {
    RecipeImageView(imageUrl: Recipe.spicyNoodles.imageUrl)
        .frame(width: 200, height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding()
}

#Preview("No image") {
    RecipeImageView(imageUrl: nil)
        .frame(width: 200, height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding()
}
