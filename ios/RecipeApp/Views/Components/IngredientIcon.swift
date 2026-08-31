//
//  IngredientIcon.swift
//  RecipeApp
//
//  Shared renderer for a resolved `GroceryItemIcon` — the bundled ingredient
//  PHOTO when one exists for the item, otherwise its category emoji. Both the
//  Grocery List (wrapped in a checked-state affordance) and the Recipe detail
//  ingredient rows draw through this one view, so the same ingredient shows the
//  same icon in both places off the same `GroceryItemIconResolver` + `ing…`
//  assets — no second copy of the matching logic anywhere.
//
//  Sizing is caller-controlled so each screen keeps its existing row layout; this
//  view only draws the glyph inside a square of the given size.
//

import SwiftUI
import RecipeKit

struct IngredientIconGlyph: View {
    let icon: GroceryItemIcon
    var size: CGFloat = 30

    /// Render from an already-resolved icon (Grocery List passes this).
    init(icon: GroceryItemIcon, size: CGFloat = 30) {
        self.icon = icon
        self.size = size
    }

    /// Resolve straight from an ingredient name (Recipe detail passes this).
    init(name: String, size: CGFloat = 30) {
        self.icon = GroceryItemIconResolver.icon(for: name)
        self.size = size
    }

    var body: some View {
        Group {
            switch icon {
            case .photo(let key):
                Image(GroceryItemPhoto.assetName(forKey: key))
                    .resizable()
                    .scaledToFit()
                    .padding(1)
            case .emoji(let emoji):
                // Emoji sized to sit within the square like the photo does.
                Text(emoji).font(.system(size: size * 0.73))
            }
        }
        .frame(width: size, height: size)
    }
}
