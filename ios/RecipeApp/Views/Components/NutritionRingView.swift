//
//  NutritionRingView.swift
//  RecipeApp
//
//  Compact donut ring showing calorie-share of protein/carbs/fat, with the
//  calorie total centered. Built as its own reusable view (RecipeDetailView
//  1.1) so it can be reused wherever a calorie/macro summary belongs — recipe
//  detail today, Meal Plan summaries later.
//
//  Segments are split by share of CALORIES (protein×4, carbs×4, fat×9), not
//  grams — see `Nutrition.calorieShare` (RecipeKit). The ring itself only
//  needs raw macro grams (share is basis-invariant); the caller resolves and
//  passes the already-per-serving calorie number for the center label.
//

import SwiftUI
import RecipeKit

struct NutritionRingView: View {
    let nutrition: Nutrition
    /// Already resolved to per-serving (or whole-recipe-fallback) — this view
    /// does no basis conversion itself.
    let displayCalories: Int?
    var diameter: CGFloat = 132
    var lineWidth: CGFloat = 14

    private struct Segment: Identifiable {
        let id: Int
        let color: Color
        let start: Double
        let end: Double
    }

    /// Small angular gap (as a fraction of the full circle) between segments,
    /// starting at 12 o'clock and going clockwise (the `rotationEffect` below).
    private static let gapFraction: Double = 0.02

    private var segments: [Segment] {
        let raw: [(Color, Double)] = [
            (.sageAccent, (nutrition.proteinG ?? 0) * 4),
            (.nutritionCarbs, (nutrition.carbsG ?? 0) * 4),
            (.nutritionFat, (nutrition.fatG ?? 0) * 9),
        ].filter { $0.1 > 0 }
        let total = raw.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return [] }

        let gap = raw.count > 1 ? Self.gapFraction : 0
        var cursor: Double = 0
        return raw.enumerated().map { index, entry in
            let fraction = entry.1 / total
            let start = cursor
            let end = cursor + fraction
            cursor = end
            return Segment(id: index, color: entry.0, start: start + gap / 2, end: max(start + gap / 2, end - gap / 2))
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.nutritionTrack, lineWidth: lineWidth)
            ForEach(segments) { segment in
                Circle()
                    .trim(from: segment.start, to: segment.end)
                    .stroke(segment.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 2) {
                Text(displayCalories.map(String.init) ?? "—")
                    .font(.editorialTitle(size: 30, relativeTo: .title))
                    .foregroundStyle(Color.textPrimary)
                Text("kcal")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.nutritionCaption)
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

/// Locked placeholder ring for a free account: a single grey track with a
/// lock glyph centered, no macro segments or calorie number.
struct LockedNutritionRingView: View {
    var diameter: CGFloat = 132
    var lineWidth: CGFloat = 14

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.nutritionTrack, lineWidth: lineWidth)
            Image(systemName: "lock.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.nutritionCaption)
        }
        .frame(width: diameter, height: diameter)
    }
}

#Preview("Ring") {
    NutritionRingView(
        nutrition: Nutrition(calories: 373, proteinG: 24, carbsG: 37, fatG: 12, basis: .perServing, source: .estimated),
        displayCalories: 373
    )
    .padding()
}

#Preview("Locked ring") {
    LockedNutritionRingView()
        .padding()
}
