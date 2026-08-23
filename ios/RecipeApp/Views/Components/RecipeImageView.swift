//
//  RecipeImageView.swift
//  RecipeApp
//
//  Loads a recipe image with graceful fallbacks. When `imageUrl` is nil, the
//  URL is malformed, or the load fails, it shows a bundled generic food photo
//  rather than a broken-image icon or a crash (CLAUDE.md: never show a broken
//  image). The generic photo is chosen deterministically from `fallbackSeed`
//  (the recipe id) so a given recipe always shows the same one — see
//  DefaultRecipeImage. Callers pair `image_source == .none` with a
//  "No photo available" badge so it's clear this isn't the real dish.
//

import SwiftUI
import RecipeKit

struct RecipeImageView: View {
    let imageUrl: String?
    /// Stable seed (recipe id) for picking the bundled fallback photo.
    /// When nil, a default seed is used (previews / id-less contexts).
    var fallbackSeed: String? = nil
    /// Recipe title, used to pick a category-matched fallback pool before the
    /// generic random one. When nil, the random pool is used.
    var fallbackTitle: String? = nil
    /// Point size for the placeholder glyph, scaled to the usage site. Only used
    /// for the icon fallback when no bundled image can be loaded.
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
                    fallback
                case .empty:
                    ZStack {
                        placeholderBackground
                        ProgressView()
                    }
                @unknown default:
                    fallback
                }
            }
        } else {
            fallback
        }
    }

    /// The deterministic bundled generic photo. Falls back to a plain icon only
    /// if the asset can't be found (should not happen in a correct build).
    private var fallback: some View {
        let name = DefaultRecipeImage.assetName(for: fallbackSeed, title: fallbackTitle)
        return ZStack {
            placeholderBackground
            if let uiImage = UIImage(named: name) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "fork.knife")
                    .font(.system(size: placeholderSymbolSize, weight: .light))
                    .foregroundStyle(Color.textSecondary)
            }
        }
    }

    private var placeholderBackground: some View {
        Rectangle()
            .fill(Color.borderWarm)
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
