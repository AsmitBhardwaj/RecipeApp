//
//  IngredientText.swift
//  RecipeApp
//
//  Shared ingredient-line renderer. The formatter lives in RecipeKit so parsed
//  and unparsed ingredient shapes follow one tested rule; this view supplies
//  only the inline bold treatment and inherits font, colour, and accessibility
//  behavior from its call site.
//

import SwiftUI
import RecipeKit

struct IngredientText: View {
    private let parts: IngredientTextParts

    init(ingredient: Ingredient, scaledBy ratio: Double? = nil) {
        parts = IngredientTextFormatter.parts(for: ingredient, scaledBy: ratio)
    }

    var body: some View {
        if let measurement = parts.measurement {
            Text(measurement).bold() + Text(parts.remainder)
        } else {
            Text(parts.remainder)
        }
    }
}

