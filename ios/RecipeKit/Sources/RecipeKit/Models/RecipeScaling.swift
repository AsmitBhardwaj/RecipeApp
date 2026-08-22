//
//  RecipeScaling.swift
//  RecipeKit
//
//  Pure (UI-free) logic behind the recipe-detail serving-size adjuster. The
//  stored `Recipe` is never mutated — the view layer holds a target serving
//  count and derives scaled *display* strings from these helpers. Kept out of
//  `Recipe.swift` so the decoded model stays a plain data mirror of the backend,
//  and out of the app target so it stays unit-testable without SwiftUI.
//
//  Scaling rule (agreed with product): displayed amount = quantity *
//  (currentServings / baseServings), with the result snapped to the nearest
//  practical cooking fraction for readability (see `fractionalQuantityString`).
//

import Foundation

// MARK: - Fraction snapping

/// The fractional parts a real recipe actually uses — eighths plus thirds — each
/// paired with its Unicode vulgar-fraction glyph. Kept sorted by value.
private let fractionGlyphs: [(value: Double, glyph: String)] = [
    (1.0 / 8.0, "\u{215B}"),  // ⅛
    (1.0 / 4.0, "\u{00BC}"),  // ¼
    (1.0 / 3.0, "\u{2153}"),  // ⅓
    (3.0 / 8.0, "\u{215C}"),  // ⅜
    (1.0 / 2.0, "\u{00BD}"),  // ½
    (5.0 / 8.0, "\u{215D}"),  // ⅝
    (2.0 / 3.0, "\u{2154}"),  // ⅔
    (3.0 / 4.0, "\u{00BE}"),  // ¾
    (7.0 / 8.0, "\u{215E}"),  // ⅞
]

public extension Double {
    /// Formats a (possibly scaled) quantity for display, snapping its fractional
    /// part to the nearest practical cooking fraction (⅛ ¼ ⅓ ⅜ ½ ⅝ ⅔ ¾ ⅞) when
    /// that fraction lands within `tolerance`. A value whose fractional part does
    /// NOT cleanly resolve to one of those (i.e. the nearest is farther than
    /// `tolerance`) falls back to one decimal place, so we never force an
    /// obviously-wrong fraction onto an odd ratio.
    ///
    /// `tolerance` is an absolute distance on the 0..<1 fractional part. The
    /// default of 0.05 was chosen against the eighths+thirds snap set: the widest
    /// gap between adjacent snap points is 1/8, so the worst a value can sit from
    /// its nearest snap point is 1/16 (≈0.0625). A 0.05 window therefore accepts
    /// any quantity that rounds cleanly to a nice fraction and rejects only the
    /// genuinely-in-between values (e.g. 0.1875 → "0.2", not a fake ⅕), which is
    /// exactly the "don't invent a wrong fraction" behaviour we want.
    func fractionalQuantityString(tolerance: Double = 0.05) -> String {
        guard isFinite, self >= 0 else { return quantityString }

        var whole = (self).rounded(.down)
        let frac = self - whole

        // Fractional part rounds away to a whole number at either end.
        if frac <= tolerance {
            return String(Int(whole))
        }
        if frac >= 1 - tolerance {
            whole += 1
            return String(Int(whole))
        }

        // Nearest practical fraction to the leftover fractional part.
        var best: (glyph: String, distance: Double)?
        for candidate in fractionGlyphs {
            let distance = abs(frac - candidate.value)
            if best == nil || distance < best!.distance {
                best = (candidate.glyph, distance)
            }
        }
        if let best, best.distance <= tolerance {
            let wholePart = whole == 0 ? "" : String(Int(whole))
            return wholePart + best.glyph
        }

        // Didn't resolve to a clean fraction — show a rounded decimal instead of
        // faking one. `quantityString` trims any trailing ".0".
        let roundedToTenths = (self * 10).rounded() / 10
        return roundedToTenths.quantityString
    }
}

// MARK: - Scaled ingredient display

public extension Ingredient {
    /// This ingredient's display line with its quantity multiplied by `ratio`
    /// (target ÷ base servings). Ingredients with no numeric `quantity` — e.g.
    /// structured/JSON-LD lines, where the entire line is unparsed text in
    /// `name` — are returned unchanged: there is nothing to scale. Assembly
    /// otherwise mirrors `displayString`.
    func displayString(scaledBy ratio: Double, tolerance: Double = 0.05) -> String {
        guard let quantity else { return displayString }
        var parts: [String] = [(quantity * ratio).fractionalQuantityString(tolerance: tolerance)]
        if let unit { parts.append(unit) }
        parts.append(name)
        var line = parts.joined(separator: " ")
        if let notes, !notes.isEmpty {
            line += " (\(notes))"
        }
        return line
    }
}

// MARK: - Recipe gating

public extension Recipe {
    /// The numeric base serving count to scale from, or nil when it is unknown.
    /// Only a positive numeric `amount` qualifies — a unit-only serving size
    /// ("1 loaf") or a missing one gives us no base to divide by.
    var baseServings: Double? {
        guard let amount = servings.amount, amount > 0 else { return nil }
        return amount
    }

    /// Whether the serving-size adjuster should be offered for this recipe.
    ///
    /// Requires BOTH a known numeric base serving count AND at least one
    /// ingredient carrying a numeric quantity to scale. Structured/JSON-LD
    /// recipes fail the second test — their ingredient lines are unparsed text
    /// with `quantity == nil` — so the control stays hidden for them even when
    /// `recipeYield` gave a base count. Offering a stepper that left every
    /// ingredient unchanged would be a quietly-broken feature.
    var canScaleServings: Bool {
        baseServings != nil && ingredients.contains { $0.quantity != nil }
    }
}
