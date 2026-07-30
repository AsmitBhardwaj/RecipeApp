//
//  GroceryList.swift
//  RecipeKit
//
//  Pure, testable logic for turning a set of planned recipes into a shopping
//  list. Kept free of any UI or persistence so it can be exercised in isolation
//  and reused if the grocery list ever appears elsewhere.
//
//  Two pieces:
//   • GroceryCategorizer — offline keyword heuristic mapping an ingredient name
//     to a `GroceryCategory`. Free, instant, imperfect on unusual items (they
//     land in `.other`); the documented tradeoff vs. an LLM call per view.
//   • GroceryAggregator — merges ingredients across recipes. It combines only
//     what's SAFE to combine: same name + same unit gets summed. Different units
//     for the same name (cups vs. grams) stay as SEPARATE line items — no unit
//     conversion, which is a much larger feature and out of scope for v1.
//

import Foundation

// MARK: - Merged line item

/// One row in the shopping list — the result of merging every ingredient that
/// shares a normalized name AND unit across the selected recipes.
public struct GroceryLineItem: Identifiable, Hashable {
    /// Display name, cased as first seen (e.g. "Olive Oil").
    public let name: String
    /// Summed quantity across merged occurrences, or nil if none were quantified.
    public let quantity: Double?
    /// The shared unit for this line (nil for unquantified / colloquial items).
    public let unit: String?
    public let category: GroceryCategory
    /// Titles of the recipes that contributed to this line, for traceability.
    public let sources: [String]

    public init(name: String, quantity: Double?, unit: String?, category: GroceryCategory, sources: [String]) {
        self.name = name
        self.quantity = quantity
        self.unit = unit
        self.category = category
        self.sources = sources
    }

    /// Period-independent identity: name + unit + category. The grocery view
    /// prepends the period (day/week) to form the key that checked-state is
    /// stored under, so re-deriving the list re-matches the same checkmarks even
    /// as the underlying recipe set shifts.
    public var stableKey: String {
        "\(name.lowercased())|\(unit?.lowercased() ?? "")|\(category.rawValue)"
    }

    public var id: String { stableKey }

    /// "3 cup flour", "2 tbsp olive oil", or just "salt" when unquantified.
    public var displayString: String {
        var parts: [String] = []
        if let quantity { parts.append(quantity.quantityString) }
        if let unit, !unit.isEmpty { parts.append(unit) }
        parts.append(name)
        return parts.joined(separator: " ")
    }
}

// MARK: - Aggregation

public enum GroceryAggregator {

    /// Merge every ingredient across `recipes` into grouped line items.
    ///
    /// Merge rule: group by (normalized name, normalized unit). Quantities within
    /// a group are summed when present; a group with no quantities at all becomes
    /// an unquantified line. A name appearing with two different units yields two
    /// lines (no conversion) — they'll sit adjacent under the same category.
    ///
    /// A recipe assigned twice to the period contributes twice (quantities double),
    /// which is the correct behavior for a shopping list.
    public static func aggregate(recipes: [Recipe]) -> [GroceryLineItem] {
        struct Bucket {
            var name: String
            var unit: String?
            var quantity: Double?
            var category: GroceryCategory
            var sources: [String]
        }

        var buckets: [String: Bucket] = [:]
        var order: [String] = [] // preserve first-seen order for stable output

        for recipe in recipes {
            for ingredient in recipe.ingredients {
                let name = ingredient.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                let unitNorm = ingredient.unit?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let key = "\(name.lowercased())|\(unitNorm ?? "")"

                if var bucket = buckets[key] {
                    if let q = ingredient.quantity {
                        bucket.quantity = (bucket.quantity ?? 0) + q
                    }
                    if !bucket.sources.contains(recipe.title) {
                        bucket.sources.append(recipe.title)
                    }
                    buckets[key] = bucket
                } else {
                    buckets[key] = Bucket(
                        name: name,
                        unit: ingredient.unit,
                        quantity: ingredient.quantity,
                        category: GroceryCategorizer.category(for: name),
                        sources: [recipe.title]
                    )
                    order.append(key)
                }
            }
        }

        return order.compactMap { buckets[$0] }.map {
            GroceryLineItem(
                name: $0.name,
                quantity: $0.quantity,
                unit: $0.unit,
                category: $0.category,
                sources: $0.sources
            )
        }
    }
}

// MARK: - Categorization heuristic

public enum GroceryCategorizer {

    /// Map an ingredient name to a shopping category by keyword. Matched in
    /// priority order (most specific categories first) so e.g. "chicken broth"
    /// resolving to Pantry can be handled before the bare-protein Meat rule.
    /// Anything unmatched is `.other`.
    public static func category(for name: String) -> GroceryCategory {
        let n = name.lowercased()

        for (category, keywords) in orderedKeywords {
            if keywords.contains(where: { n.contains($0) }) {
                return category
            }
        }
        return .other
    }

    /// (category, keywords) in match-priority order — NOT display order. Earlier
    /// entries win, so overrides for tricky items (broth/stock → pantry before
    /// the meat rule; bell pepper → produce before "pepper" → pantry) come first.
    private static let orderedKeywords: [(GroceryCategory, [String])] = [
        // Pantry overrides that would otherwise be miscaught by a broader rule.
        (.pantry, [
            "broth", "stock", "bouillon",
            "bell pepper", "red pepper flake", "chili flake", "pepper flake",
            "peppercorn", "black pepper", "white pepper", "cayenne",
        ]),
        // Produce — fresh fruit, vegetables, herbs, aromatics.
        (.produce, [
            "lettuce", "tomato", "onion", "garlic", "potato", "carrot", "celery",
            "spinach", "kale", "arugula", "cucumber", "avocado", "lemon", "lime",
            "apple", "banana", "berry", "strawberr", "blueberr", "raspberr",
            "grape", "orange", "mango", "pineapple", "peach", "pear", "melon",
            "basil", "cilantro", "parsley", "mint", "thyme", "rosemary", "dill",
            "ginger", "scallion", "shallot", "leek", "mushroom", "broccoli",
            "cauliflower", "zucchini", "squash", "cabbage", "jalapeno", "jalapeño",
            "chili", "chile", "bell pepper", "pepper", "corn", "cucumber",
            "eggplant", "asparagus", "radish", "beet", "herb",
        ]),
        // Meat & Seafood.
        (.meatSeafood, [
            "chicken", "beef", "pork", "bacon", "sausage", "turkey", "lamb",
            "steak", "ground meat", "mince", "prosciutto", "pepperoni", "ham",
            "fish", "salmon", "tuna", "shrimp", "prawn", "cod", "tilapia",
            "crab", "lobster", "scallop", "clam", "mussel", "anchovy", "meat",
        ]),
        // Dairy & Eggs.
        (.dairyEggs, [
            "milk", "cheese", "butter", "cream", "yogurt", "yoghurt", "egg",
            "parmesan", "parmigiano", "mozzarella", "cheddar", "feta", "ricotta",
            "mascarpone", "gouda", "brie", "buttermilk", "half and half",
        ]),
        // Bakery.
        (.bakery, [
            "bread", "bun", "bagel", "tortilla", "baguette", "roll", "pita",
            "croissant", "naan", "brioche", "loaf", "ciabatta", "focaccia",
        ]),
        // Frozen.
        (.frozen, [
            "frozen", "ice cream", "ice ",
        ]),
        // Pantry — shelf-stable staples, spices, oils, canned goods, dry goods.
        (.pantry, [
            "flour", "sugar", "salt", "oil", "vinegar", "rice", "pasta", "noodle",
            "spaghetti", "sauce", "soy sauce", "ketchup", "mustard", "mayo",
            "honey", "syrup", "baking soda", "baking powder", "yeast", "oats",
            "cereal", "spice", "cumin", "paprika", "cinnamon", "nutmeg", "vanilla",
            "chocolate", "cocoa", "canned", "tomato paste", "coconut milk",
            "lentil", "chickpea", "bean", "peanut butter", "jam", "jelly", "tea",
            "coffee", "wine", "almond", "walnut", "cashew", "pecan", "nut", "seed",
            "cornstarch", "breadcrumb", "gelatin", "stock cube", "curry", "sesame",
            "turmeric", "oregano", "garlic powder", "onion powder", "broth",
        ]),
    ]
}
