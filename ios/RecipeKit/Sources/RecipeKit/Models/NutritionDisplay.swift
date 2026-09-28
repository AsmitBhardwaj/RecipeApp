//
//  NutritionDisplay.swift
//  RecipeKit
//
//  Pure (UI-free) math behind the recipe-detail nutrition card: always-per-
//  serving values regardless of the backend's `basis`, and calorie-share
//  percentages for the donut ring's legend. Kept out of the view layer so it's
//  unit-testable without SwiftUI, mirroring RecipeScaling.swift.
//

import Foundation

public extension Nutrition {
    struct PerServingResult: Hashable {
        public let calories: Int?
        public let proteinG: Int?
        public let carbsG: Int?
        public let fatG: Int?
        /// "Per serving" or "Whole recipe" — the caption's basis clause.
        public let captionPrefix: String
    }

    /// Resolves this nutrition to always-per-serving whole-number values.
    ///
    /// - `basis == .perServing`: values are used as-is (already per serving).
    /// - `basis == .perRecipe`: divides by `originalServings` — the recipe's
    ///   ORIGINAL base serving count (`Recipe.baseServings`), never the live
    ///   scaled count from the servings stepper, so the stepper can never move
    ///   these numbers.
    /// - No known `originalServings` to divide by: falls back to showing the
    ///   whole-recipe totals with an honest "Whole recipe" caption rather than
    ///   mislabeling them as per-serving.
    func perServingDisplay(originalServings: Double?) -> PerServingResult {
        func rounded(_ value: Double?, dividingBy divisor: Double) -> Int? {
            value.map { Int(($0 / divisor).rounded()) }
        }

        switch basis {
        case .perServing:
            return PerServingResult(
                calories: rounded(calories, dividingBy: 1),
                proteinG: rounded(proteinG, dividingBy: 1),
                carbsG: rounded(carbsG, dividingBy: 1),
                fatG: rounded(fatG, dividingBy: 1),
                captionPrefix: "Per serving"
            )
        case .perRecipe:
            guard let originalServings, originalServings > 0 else {
                return PerServingResult(
                    calories: rounded(calories, dividingBy: 1),
                    proteinG: rounded(proteinG, dividingBy: 1),
                    carbsG: rounded(carbsG, dividingBy: 1),
                    fatG: rounded(fatG, dividingBy: 1),
                    captionPrefix: "Whole recipe"
                )
            }
            return PerServingResult(
                calories: rounded(calories, dividingBy: originalServings),
                proteinG: rounded(proteinG, dividingBy: originalServings),
                carbsG: rounded(carbsG, dividingBy: originalServings),
                fatG: rounded(fatG, dividingBy: originalServings),
                captionPrefix: "Per serving"
            )
        }
    }

    /// "Estimated" or "From creator" — the caption's provenance clause.
    var sourceCaption: String {
        source == .creatorStated ? "From creator" : "Estimated"
    }
}

/// Percent of total calories contributed by each macro (protein×4, carbs×4,
/// fat×9), always summing to exactly 100. Scale-invariant — the same whether
/// computed from whole-recipe or per-serving grams — so it needs no serving
/// count.
public struct MacroCalorieShare: Hashable {
    public let proteinPercent: Int
    public let carbsPercent: Int
    public let fatPercent: Int
}

public extension Nutrition {
    /// nil when no macro contributes any calories (nothing to show a share of).
    var calorieShare: MacroCalorieShare? {
        let proteinKcal = (proteinG ?? 0) * 4
        let carbsKcal = (carbsG ?? 0) * 4
        let fatKcal = (fatG ?? 0) * 9
        let total = proteinKcal + carbsKcal + fatKcal
        guard total > 0 else { return nil }

        let raw = [proteinKcal, carbsKcal, fatKcal].map { $0 / total * 100 }
        let floors = raw.map { Int($0) }
        var values = floors
        // Largest-remainder method: independent rounding can drift to 99 or
        // 101, so hand the leftover percentage point(s) to whichever value(s)
        // were closest to rounding up, guaranteeing the three sum to 100.
        let deficit = 100 - floors.reduce(0, +)
        let remainderOrder = raw.enumerated()
            .sorted { ($0.element - Double(floors[$0.offset])) > ($1.element - Double(floors[$1.offset])) }
            .map(\.offset)
        for i in 0..<max(0, deficit) {
            values[remainderOrder[i % values.count]] += 1
        }
        return MacroCalorieShare(proteinPercent: values[0], carbsPercent: values[1], fatPercent: values[2])
    }
}
