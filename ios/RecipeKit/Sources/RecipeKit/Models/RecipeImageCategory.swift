//
//  RecipeImageCategory.swift
//  RecipeKit
//
//  Maps a recipe TITLE to a food category, used to pick a category-matched
//  bundled fallback image (client-side) before falling back to a random bundled
//  image. Title-only by design — no ingredient parsing, no caption (the caption
//  isn't available on the client).
//
//  Two tiers, checked in order:
//    1. Specific dish-name overrides (multi-word phrases), matched as substrings.
//    2. Generic single-word keywords, matched against the title's word tokens
//       (first token that maps wins — so protein-forward titles like
//       "Chicken Fried Rice" resolve by their leading keyword).
//
//  This is a deliberately simple, editable heuristic — expand the tables freely.
//

import Foundation

public enum RecipeImageCategory: String, CaseIterable, Hashable, Sendable {
    case chicken
    case beef
    case pork
    case seafood        // shellfish: shrimp, crab, scallop, …
    case fish           // finfish: salmon, tuna, cod, …
    case pasta
    case rice
    case soup           // soup / stew / chili / curry / chowder
    case salad
    case dessert
    case breakfastBaked // pancakes, eggs, pastries, bread
}

public enum RecipeImageCategorizer {

    /// Tier 1 — multi-word dish overrides, checked (in this order) before any
    /// keyword. Order matters: list more-specific phrases first.
    static let overrides: [(phrase: String, category: RecipeImageCategory)] = [
        ("chicken tikka masala", .chicken),
        ("butter chicken", .chicken),
        ("chicken parmigiana", .chicken),
        ("chicken parmesan", .chicken),
        ("chicken alfredo", .pasta),
        ("chicken noodle soup", .soup),
        ("chicken pot pie", .chicken),
        ("pot pie", .chicken),
        ("beef bourguignon", .beef),
        ("beef wellington", .beef),
        ("beef stew", .soup),
        ("shepherd's pie", .beef),
        ("shepherds pie", .beef),
        ("shrimp scampi", .seafood),
        ("fish and chips", .fish),
        ("clam chowder", .soup),
        ("spaghetti bolognese", .pasta),
        ("spaghetti carbonara", .pasta),
        ("mac and cheese", .pasta),
        ("pad thai", .seafood),
        ("pad see ew", .pasta),
        ("caesar salad", .salad),
        ("greek salad", .salad),
        ("cobb salad", .salad),
        ("fried rice", .rice),
        ("jollof rice", .rice),
        ("french toast", .breakfastBaked),
        ("eggs benedict", .breakfastBaked),
        ("banana bread", .breakfastBaked),
        ("chocolate chip cookies", .dessert),
    ]

    /// Tier 2 — single-word keywords, matched against the title's word tokens.
    static let keywords: [String: RecipeImageCategory] = [
        // chicken
        "chicken": .chicken, "poultry": .chicken,
        // beef
        "beef": .beef, "steak": .beef, "brisket": .beef, "meatball": .beef,
        "meatballs": .beef, "burger": .beef, "cheeseburger": .beef, "pho": .beef,
        // pork
        "pork": .pork, "bacon": .pork, "ham": .pork, "sausage": .pork,
        "pancetta": .pork, "prosciutto": .pork, "chorizo": .pork, "ribs": .pork,
        // seafood (shellfish)
        "shrimp": .seafood, "prawn": .seafood, "prawns": .seafood, "crab": .seafood,
        "scallop": .seafood, "scallops": .seafood, "lobster": .seafood,
        "calamari": .seafood, "mussels": .seafood, "clam": .seafood,
        "clams": .seafood, "oyster": .seafood, "sushi": .seafood, "paella": .seafood,
        // fish (finfish)
        "salmon": .fish, "tuna": .fish, "cod": .fish, "tilapia": .fish,
        "halibut": .fish, "trout": .fish, "fish": .fish, "mahi": .fish,
        // pasta
        "pasta": .pasta, "spaghetti": .pasta, "noodle": .pasta, "noodles": .pasta,
        "mac": .pasta, "macaroni": .pasta, "lasagna": .pasta, "lasagne": .pasta,
        "penne": .pasta, "fettuccine": .pasta, "alfredo": .pasta, "carbonara": .pasta,
        "ravioli": .pasta, "gnocchi": .pasta, "linguine": .pasta, "ramen": .soup,
        // rice
        "rice": .rice, "risotto": .rice, "pilaf": .rice, "biryani": .rice,
        "bibimbap": .rice, "jambalaya": .rice,
        // soup
        "soup": .soup, "stew": .soup, "chili": .soup, "broth": .soup,
        "curry": .soup, "chowder": .soup, "bisque": .soup,
        // salad
        "salad": .salad, "slaw": .salad, "coleslaw": .salad,
        // dessert
        "cake": .dessert, "cookie": .dessert, "cookies": .dessert, "brownie": .dessert,
        "brownies": .dessert, "pie": .dessert, "dessert": .dessert, "cheesecake": .dessert,
        "cupcake": .dessert, "pudding": .dessert, "tart": .dessert, "donut": .dessert,
        "doughnut": .dessert, "tiramisu": .dessert,
        // breakfast / baked
        "pancake": .breakfastBaked, "pancakes": .breakfastBaked, "waffle": .breakfastBaked,
        "waffles": .breakfastBaked, "egg": .breakfastBaked, "eggs": .breakfastBaked,
        "omelette": .breakfastBaked, "omelet": .breakfastBaked, "toast": .breakfastBaked,
        "bagel": .breakfastBaked, "muffin": .breakfastBaked, "bread": .breakfastBaked,
        "croissant": .breakfastBaked, "scone": .breakfastBaked, "granola": .breakfastBaked,
        "oatmeal": .breakfastBaked, "frittata": .breakfastBaked,
    ]

    /// The category for a recipe title, or nil when nothing matches (caller then
    /// falls back to the random bundled pool).
    public static func category(for title: String) -> RecipeImageCategory? {
        let lower = title.lowercased()

        // Tier 1: dish-name overrides (substring).
        for override in overrides where lower.contains(override.phrase) {
            return override.category
        }

        // Tier 2: single-word keywords, first matching token wins.
        let tokens = lower.split { !$0.isLetter }.map(String.init)
        for token in tokens {
            if let category = keywords[token] {
                return category
            }
        }
        return nil
    }
}
