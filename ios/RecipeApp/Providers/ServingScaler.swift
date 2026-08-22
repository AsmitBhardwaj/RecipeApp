//
//  ServingScaler.swift
//  RecipeApp
//
//  View model behind the recipe-detail serving-size adjuster. Holds only the
//  user's chosen target serving count; the stored `Recipe` is never mutated.
//  `RecipeDetailView` reads `ratio` to derive scaled ingredient display strings
//  (see RecipeKit's `Ingredient.displayString(scaledBy:)`).
//
//  Instantiated for every detail view, but only actually surfaced when
//  `recipe.canScaleServings` is true (a known numeric base + at least one
//  numeric ingredient quantity).
//

import Foundation
import RecipeKit

@MainActor
final class ServingScaler: ObservableObject {
    /// The recipe's original serving count — the denominator for scaling and the
    /// "originally N" reference. Never below 1.
    let baseServings: Double

    /// The user's current target serving count. Whole-serving steps within
    /// `range`. Drives `ratio` and, through it, every scaled ingredient.
    @Published var currentServings: Double

    /// Never below 1 serving; capped generously so the stepper can't run away.
    let range: ClosedRange<Double>

    init(baseServings: Double) {
        let base = max(1, baseServings)
        self.baseServings = base
        self.currentServings = base
        self.range = 1...max(base * 4, 24)
    }

    /// Scale factor applied to each numeric ingredient quantity.
    var ratio: Double { currentServings / baseServings }

    /// Whether the user has moved off the recipe's original serving count.
    var isScaled: Bool { currentServings != baseServings }

    var canDecrement: Bool { currentServings > range.lowerBound }
    var canIncrement: Bool { currentServings < range.upperBound }

    func increment() {
        currentServings = min(range.upperBound, currentServings + 1)
    }

    func decrement() {
        currentServings = max(range.lowerBound, currentServings - 1)
    }
}
