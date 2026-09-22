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

/// The two typographic portions of an ingredient line. `measurement` contains
/// only the leading quantity plus its unit/size descriptor; `remainder` keeps
/// its original leading space so joining the values reproduces the source line.
public struct IngredientTextParts: Equatable, Sendable {
    public let measurement: String?
    public let remainder: String

    public init(measurement: String?, remainder: String) {
        self.measurement = measurement
        self.remainder = remainder
    }
}

/// Shared formatter for ingredient emphasis. Structured ingredients use their
/// explicit quantity/unit, while unparsed JSON-LD ingredient lines fall back to
/// a conservative leading-text parser.
public enum IngredientTextFormatter {
    public static func parts(for ingredient: Ingredient, scaledBy ratio: Double? = nil) -> IngredientTextParts {
        let line: String
        let knownMeasurement: String?

        if let ratio, let quantity = ingredient.quantity {
            let amount = (quantity * ratio).fractionalQuantityString()
            line = ingredient.displayString(scaledBy: ratio)
            knownMeasurement = [amount, ingredient.unit]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        } else {
            line = ingredient.displayString
            if let quantity = ingredient.quantity {
                knownMeasurement = [quantity.quantityString, ingredient.unit]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            } else {
                knownMeasurement = nil
            }
        }

        let parsed = parts(in: line)
        guard let knownMeasurement, line.hasPrefix(knownMeasurement) else { return parsed }

        // The parser may legitimately extend a quantity-only structured prefix
        // with a size descriptor from the ingredient name ("1 large onion").
        if let parsedMeasurement = parsed.measurement,
           parsedMeasurement.count > knownMeasurement.count {
            return parsed
        }

        return IngredientTextParts(
            measurement: knownMeasurement,
            remainder: String(line.dropFirst(knownMeasurement.count))
        )
    }

    /// Splits raw ingredient text such as "1 1/2 cups flour". If a line has no
    /// leading numeric quantity, it remains entirely regular-weight.
    public static func parts(in line: String) -> IngredientTextParts {
        let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = expression.firstMatch(in: line, range: fullRange),
              let range = Range(match.range, in: line),
              !range.isEmpty else {
            return IngredientTextParts(measurement: nil, remainder: line)
        }

        return IngredientTextParts(
            measurement: String(line[range]),
            remainder: String(line[range.upperBound...])
        )
    }

    private static let expression: NSRegularExpression = {
        let unicodeFractions = "¼½¾⅐⅑⅒⅓⅔⅕⅖⅗⅘⅙⅚⅛⅜⅝⅞"
        let number = #"(?:\d+\s+(?:\d+/\d+|["# + unicodeFractions + #"])|\d+\s*["#
            + unicodeFractions + #"]|\d+/\d+|\d+(?:\.\d+)?|\.\d+|["#
            + unicodeFractions + #"])"#
        let range = number + #"(?:\s*(?:-|–|—|to)\s*"# + number + #")?"#
        let units = #"(?:fl\.?\s*oz\.?|fluid\s+ounces?|t(?:ea)?sp(?:oons?)?\.?|tbsp\.?|tablespoons?|cups?|ounces?|oz\.?|pounds?|lbs?\.?|kilograms?|kgs?\.?|grams?|g\.?|milligrams?|mg\.?|millilit(?:er|re)s?|ml\.?|lit(?:er|re)s?|l\.?|gallons?|quarts?|pints?|sticks?|cans?|jars?|packages?|pkgs?\.?|packets?|cloves?|bunch(?:es)?|sprigs?|pinch(?:es)?|dashes?|slices?|pieces?|heads?|stalks?|handfuls?|scoops?|extra[-\s]large|x-large|large|medium|small)\b"#
        let pattern = #"^\s*"# + range + #"(?:\s+"# + units + #")?"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()
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
        // No real image for this recipe — the client shows a bundled generic
        // photo, so the badge makes clear it isn't the actual dish.
        case .none: return "No photo available"
        }
    }
}
