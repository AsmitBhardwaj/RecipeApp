//
//  GroceryItemPhoto.swift
//  RecipeApp
//
//  Bridges a `GroceryItemIconResolver` photo key to its bundled asset-catalog
//  image. Each key "onion", "chickenBreast", … has a matching `ing<Key>` image
//  set in Assets.xcassets (transparent PNG, ~200px, downscaled from the source
//  art). This mirrors how `DefaultRecipeImage` maps categories to `cat…` assets —
//  the asset-name convention lives in the app, not in RecipeKit.
//

import Foundation

enum GroceryItemPhoto {
    /// Asset-catalog name for a resolver photo key, e.g. "onion" → "ingOnion",
    /// "chickenBreast" → "ingChickenBreast".
    static func assetName(forKey key: String) -> String {
        "ing" + key.prefix(1).uppercased() + key.dropFirst()
    }
}
