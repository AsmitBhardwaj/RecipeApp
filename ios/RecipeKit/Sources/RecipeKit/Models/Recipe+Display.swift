//
//  Recipe+Display.swift
//  RecipeKit
//
//  View-facing formatting helpers derived from the model. Kept separate from
//  `Recipe.swift` so the decoded model stays a pure data mirror of the backend.
//  `public` so the app target's views can use them.
//

import Foundation

public extension Double {
    /// Formats a quantity without a trailing ".0" (e.g. 2.0 -> "2", 1.5 -> "1.5").
    var quantityString: String {
        if self == rounded() {
            return String(Int(self))
        }
        return String(self)
    }

    /// Formats a minutes value as "45 min" or "1 hr 30 min".
    var minutesString: String {
        let total = Int(rounded())
        if total < 60 { return "\(total) min" }
        let hours = total / 60
        let mins = total % 60
        return mins == 0 ? "\(hours) hr" : "\(hours) hr \(mins) min"
    }
}

public extension Servings {
    /// Human-readable servings, or nil if there is nothing to show.
    var displayString: String? {
        switch (amount, unit) {
        case let (amount?, unit?):
            return "\(amount.quantityString) \(unit)"
        case let (amount?, nil):
            let n = amount.quantityString
            return amount == 1 ? "\(n) serving" : "\(n) servings"
        case let (nil, unit?):
            return unit
        case (nil, nil):
            return nil
        }
    }
}

public extension Ingredient {
    /// Assembles "2 tbsp olive oil (extra virgin)" from the available parts.
    var displayString: String {
        var parts: [String] = []
        if let quantity { parts.append(quantity.quantityString) }
        if let unit { parts.append(unit) }
        parts.append(name)
        var line = parts.joined(separator: " ")
        if let notes, !notes.isEmpty {
            line += " (\(notes))"
        }
        return line
    }
}

public extension Recipe {
    /// Whether this recipe was generated from general culinary knowledge rather
    /// than extracted from the video (CLAUDE.md §5 — must be visually distinct).
    var isGenerated: Bool { sourceType == .generated }
}

public extension ImageSource {
    /// Short label for the persistent image-provenance badge (CLAUDE.md §5).
    /// Returns nil when there is no image to attribute.
    var badgeLabel: String? {
        switch self {
        case .videoThumbnail: return "From video"
        case .stockPhoto: return "Stock photo"
        case .webImage: return "From the site"
        case .none: return nil
        }
    }
}
