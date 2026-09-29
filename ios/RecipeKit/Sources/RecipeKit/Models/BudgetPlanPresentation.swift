//
//  BudgetPlanPresentation.swift
//  RecipeKit
//
//  Pure, testable helpers behind the "Your week" plan screen: the keyword →
//  food-sticker mapper and the grocery-list pantry matcher.
//

import Foundation

// MARK: - Food sticker

/// The sticker art categories. `assetName` is the image-asset name; the UI falls
/// back to a soft tinted square when the asset is missing.
public enum FoodSticker: String, CaseIterable, Sendable {
    case pasta, riceBowl = "rice_bowl", noodles, soup, salad, tacos, curry, chicken, seafood, generic

    public var assetName: String { "sticker_food_\(rawValue)" }

    /// Ordered rules — the first category with a matching keyword wins, so the
    /// specific dish types ("curry", "tacos") beat the bare protein ("chicken").
    private static let rules: [(FoodSticker, [String])] = [
        (.curry, ["curry", "masala", "tikka", "korma", "dal", "dhal", "vindaloo", "biryani"]),
        (.tacos, ["taco", "burrito", "quesadilla", "fajita", "enchilada", "nacho"]),
        (.noodles, ["noodle", "ramen", "pho", "udon", "soba", "lo mein", "pad thai", "chow mein"]),
        (.pasta, ["pasta", "spaghetti", "penne", "lasagna", "lasagne", "macaroni", "mac and cheese",
                  "fettuccine", "linguine", "rigatoni", "gnocchi", "carbonara",
                  "ravioli", "tortellini"]),
        (.soup, ["soup", "stew", "chili", "chowder", "broth", "bisque", "minestrone"]),
        (.salad, ["salad", "slaw", "caprese"]),
        (.seafood, ["salmon", "shrimp", "prawn", "fish", "tuna", "cod", "tilapia", "crab", "lobster",
                    "scallop", "seafood", "clam", "mussel"]),
        (.riceBowl, ["rice", "bowl", "risotto", "pilaf", "poke", "burrito bowl", "congee"]),
        (.chicken, ["chicken", "turkey", "wings", "drumstick"]),
    ]

    /// Category for a meal name (case-insensitive, whole-word / whole-phrase
    /// match); `.generic` when nothing matches.
    public static func category(forMealName name: String) -> FoodSticker {
        let words = name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let padded = " " + words.joined(separator: " ") + " "
        for (sticker, keywords) in rules {
            for keyword in keywords {
                // Plural tolerance: "tacos", "noodles", "wings".
                if padded.contains(" \(keyword) ") || padded.contains(" \(keyword)s ") || padded.contains(" \(keyword)es ") {
                    return sticker
                }
            }
        }
        return .generic
    }
}

// MARK: - Pantry matcher

/// Splits an aggregated grocery list into "still to buy" and "already in your
/// pantry". Matched items are moved, never dropped.
public enum GroceryPantryMatcher {

    public struct Split {
        public let toBuy: [GroceryLineItem]
        public let inPantry: [GroceryLineItem]
        /// The pantry item names that matched, in pantry order (for the subtitle).
        public let matchedPantryNames: [String]
    }

    /// Lowercase, trim, and singularize simply: "eggs"→"egg", "tomatoes"→"tomato",
    /// "berries"→"berry". Words ending in "ss"/"us" ("hummus" left as-is).
    public static func normalize(_ text: String) -> String {
        text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { singularize(String($0)) }
            .joined(separator: " ")
    }

    static func singularize(_ word: String) -> String {
        guard word.count > 3 else { return word }
        if word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if word.hasSuffix("oes") { return String(word.dropLast(2)) }
        if word.hasSuffix("ches") || word.hasSuffix("shes") || word.hasSuffix("xes") { return String(word.dropLast(2)) }
        if word.hasSuffix("ss") || word.hasSuffix("us") { return word }
        if word.hasSuffix("s") { return String(word.dropLast()) }
        return word
    }

    /// Word-boundary match: the pantry name's words must appear as a contiguous
    /// run of whole words in the ingredient's ("egg" matches "large egg" but not
    /// "eggplant"; "rice" doesn't match "licorice").
    public static func matches(ingredient: String, pantry: String) -> Bool {
        let hay = normalize(ingredient).split(separator: " ").map(String.init)
        let needle = normalize(pantry).split(separator: " ").map(String.init)
        guard !needle.isEmpty, needle.count <= hay.count else { return false }
        for start in 0...(hay.count - needle.count) where Array(hay[start..<start + needle.count]) == needle {
            return true
        }
        return false
    }

    public static func split(items: [GroceryLineItem], pantryNames: [String]) -> Split {
        let pantry = pantryNames.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var toBuy: [GroceryLineItem] = []
        var inPantry: [GroceryLineItem] = []
        var matched = Set<String>()
        for item in items {
            let hits = pantry.filter { matches(ingredient: item.name, pantry: $0) }
            if hits.isEmpty {
                toBuy.append(item)
            } else {
                inPantry.append(item)
                hits.forEach { matched.insert($0) }
            }
        }
        return Split(toBuy: toBuy, inPantry: inPantry, matchedPantryNames: pantry.filter { matched.contains($0) })
    }
}

// MARK: - Dinner card text

public extension PlannedRecipe {
    /// Whole-dollar cost, e.g. "$8".
    var costLabel: String { "$\(Int(estimatedCost.amount.rounded()))" }

    /// Total time if given, else prep + cook; nil when the recipe has neither.
    var timeMinutes: Double? {
        if let total = recipe.totalTimeMinutes, total > 0 { return total }
        let parts = [recipe.prepTimeMinutes, recipe.cookTimeMinutes].compactMap { $0 }
        let sum = parts.reduce(0, +)
        return sum > 0 ? sum : nil
    }

    var timeLabel: String? { timeMinutes?.minutesString }

    /// "cost · time · appliances", skipping whatever is unknown.
    var cardDetail: String {
        [costLabel, timeLabel, equipmentSummary.isEmpty ? nil : equipmentSummary]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}
