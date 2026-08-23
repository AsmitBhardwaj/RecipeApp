//
//  DefaultRecipeImage.swift
//  RecipeApp
//
//  Last-resort image fallback when a recipe has no usable image (image_source ==
//  "none") or its remote image fails to load. Resolution order:
//    1. Category-matched pool — match the recipe TITLE to a food category
//       (RecipeImageCategorizer) and pick from that category's bundled photos.
//    2. Random pool — a generic bundled photo, used only when no category matches.
//
//  In both tiers the pick is deterministic per recipe (stable hash of its id), so
//  a given recipe always shows the SAME image. These are generic stock photos,
//  NOT the recipe's actual dish, so callers pair them with a "No photo available"
//  badge for honesty.
//

import SwiftUI
import RecipeKit

enum DefaultRecipeImage {

    /// Generic photos used only when no category matches (the last resort).
    static let randomPool = [
        "defaultRecipeImage1",
        "defaultRecipeImage2",
        "defaultRecipeImage3",
        "defaultRecipeImage4",
        "defaultRecipeImage5",
    ]

    /// Category-matched photo pools (6 each), keyed by the food category the
    /// recipe title resolves to. See Assets.xcassets/cat<Category>N.
    static let categoryPools: [RecipeImageCategory: [String]] = [
        .chicken: names("catChicken"),
        .beef: names("catBeef"),
        .pork: names("catPork"),
        .seafood: names("catSeafood"),
        .fish: names("catFish"),
        .pasta: names("catPasta"),
        .rice: names("catRice"),
        .soup: names("catSoup"),
        .salad: names("catSalad"),
        .dessert: names("catDessert"),
        .breakfastBaked: names("catBreakfast"),
    ]

    private static func names(_ prefix: String, count: Int = 6) -> [String] {
        (1...count).map { "\(prefix)\($0)" }
    }

    /// Deterministic asset name for a recipe: a category-matched photo when the
    /// title matches a category, otherwise a generic one. Same seed → same image
    /// within whichever pool is chosen. A nil/empty seed still renders a photo.
    static func assetName(for seed: String?, title: String?) -> String {
        let seedValue = (seed?.isEmpty == false) ? seed! : "default"

        if let title,
           let category = RecipeImageCategorizer.category(for: title),
           let pool = categoryPools[category], !pool.isEmpty {
            return pool[stableIndex(for: seedValue, modulo: pool.count)]
        }

        return randomPool[stableIndex(for: seedValue, modulo: randomPool.count)]
    }
}
