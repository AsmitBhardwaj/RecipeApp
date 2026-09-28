//
//  NutritionCardColors.swift
//  RecipeApp
//
//  Literal design-spec colors for the recipe-detail nutrition card and source
//  row (RecipeDetailView 1.1). These are exact hex values from the design spec
//  rather than the adaptive Theme/Palette tokens — the spec calls for a fixed
//  light-mode card (white background, specific border/track/macro hues), not
//  the app's usual dark-mode-adaptive surface.
//

import SwiftUI

extension Color {
    /// Standard 6-digit hex initializer, e.g. `Color(hex: "E8E5DE")`.
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: .whitespacesAndNewlines))
            .scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// Sage accent shared by the nutrition ring's protein segment, the source
    /// row, and the "Unlock with Pro" button.
    static let sageAccent = Color(hex: "4F6446")
    static let nutritionCardBorder = Color(hex: "E8E5DE")
    static let nutritionCaption = Color(hex: "6B645B")
    static let nutritionTrack = Color(hex: "F1EFE9")
    static let nutritionCarbs = Color(hex: "C07A52")
    static let nutritionFat = Color(hex: "E2B85C")
}
