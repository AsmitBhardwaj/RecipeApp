//
//  DefaultRecipeImage.swift
//  RecipeApp
//
//  Last-resort image fallback: when a recipe has no usable image (image_source
//  == "none") or its remote image fails to load, we show one of a few bundled,
//  generic food photos instead of a plain icon. The choice is deterministic per
//  recipe (stable hash of its id) so a given recipe always shows the SAME
//  fallback — never re-randomizing on each render.
//
//  These are generic stock photos, NOT the recipe's actual dish, so callers pair
//  them with a "No photo available" badge (see ImageSource.none) for honesty.
//

import SwiftUI
import RecipeKit

enum DefaultRecipeImage {
    /// The bundled generic food photos (see Assets.xcassets/defaultRecipeImageN).
    /// Kept varied across cuisine/course so repeats across recipes don't feel samey.
    static let assetNames = [
        "defaultRecipeImage1",
        "defaultRecipeImage2",
        "defaultRecipeImage3",
        "defaultRecipeImage4",
        "defaultRecipeImage5",
    ]

    /// Deterministic asset name for `seed` (a recipe id). Same seed → same image
    /// across launches. `nil`/empty seed falls back to the first image so
    /// previews and id-less contexts still render a photo.
    static func assetName(for seed: String?) -> String {
        guard let seed, !seed.isEmpty else { return assetNames[0] }
        return assetNames[stableIndex(for: seed, modulo: assetNames.count)]
    }
}
