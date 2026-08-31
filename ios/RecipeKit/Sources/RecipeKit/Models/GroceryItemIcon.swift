//
//  GroceryItemIcon.swift
//  RecipeKit
//
//  Resolves an individual grocery item to the icon shown in place of its checkbox
//  circle: a bundled ingredient PHOTO when we have one for that ingredient,
//  otherwise the emoji from `GroceryItemEmoji` as the generic per-item fallback.
//
//  Like `GroceryItemEmoji`, matching is name-based and ORDERED (first match wins),
//  so specificity is encoded by position. Two extra wrinkles vs. the emoji table:
//
//   • A table entry may map to `nil` — a "we have no photo for this" guard placed
//     ABOVE a generic keyword, so qualified forms that merely share a word with a
//     photographed ingredient ("chicken broth", "garlic powder", "sweet potato",
//     "eggplant", "peanut butter") fall through to the emoji instead of borrowing
//     the wrong photo.
//   • The `.photo` case carries a CANONICAL KEY (e.g. "chickenBreast"), not an
//     asset name — the app maps the key to its bundled `ing<Key>` image set. This
//     keeps RecipeKit free of any asset-catalog knowledge (mirrors how
//     `RecipeImageCategorizer` stays separate from `DefaultRecipeImage`).
//

import Foundation

public enum GroceryItemIcon: Equatable, Sendable {
    /// A bundled ingredient photo, identified by its canonical key.
    case photo(String)
    /// No photo for this item — show this emoji instead.
    case emoji(String)
}

public enum GroceryItemIconResolver {

    /// Photo when the item maps to a bundled ingredient image, else the emoji
    /// fallback. See `photoKey(for:)` for the matching rules.
    public static func icon(for name: String) -> GroceryItemIcon {
        if let key = photoKey(for: name) {
            return .photo(key)
        }
        return .emoji(GroceryItemEmoji.emoji(for: name))
    }

    /// The canonical photo key for an item name, or nil when no bundled photo
    /// fits (caller then falls back to the emoji). First matching row wins; a row
    /// whose key is nil is an explicit "no photo" guard (see file header).
    public static func photoKey(for name: String) -> String? {
        let n = name.lowercased()
        for row in table where row.keywords.contains(where: { n.contains($0) }) {
            return row.key
        }
        return nil
    }

    /// (keywords, key?) in match-priority order. EARLIER ROWS WIN. A nil key means
    /// "explicitly no photo — use the emoji"; it sits above the generic keyword it
    /// guards. Keys are the camelCase asset stems the app resolves to `ing<Key>`.
    private static let table: [(keywords: [String], key: String?)] = [

        // ── "No photo" guards ─ qualified forms that share a word with a
        //    photographed ingredient but AREN'T it. Must precede those words.
        (["broth", "stock", "bouillon"], nil),
        (["garlic powder", "onion powder", "chili powder", "chili flake",
          "red pepper", "pepper flake", "cornstarch", "corn starch"], nil),
        (["peanut butter"], nil),
        (["cream cheese"], nil),
        (["coconut"], nil),                       // incl. coconut milk
        (["sweet potato"], nil),
        (["eggplant"], nil),
        (["pineapple"], nil),
        (["green onion", "scallion"], nil),
        (["chili crisp", "chili oil"], nil),
        (["soy sauce", "fish sauce", "hot sauce", "tomato sauce",
          "tomato paste"], nil),
        (["olive oil", "sesame oil", "vegetable oil", "canola oil"], nil),
        (["vanilla", "extract"], nil),

        // ── Meat & poultry ───────────────────────────────────────────────
        (["chicken thigh"], "chickenThigh"),
        (["chicken breast", "chicken"], "chickenBreast"),
        (["ground beef", "ground chuck", "mince"], "groundBeef"),
        (["steak", "beef", "brisket"], "beefSteak"),
        (["pork chop", "pork", "chop"], "porkChop"),
        (["bacon"], "bacon"),

        // ── Dairy & eggs ─────────────────────────────────────────────────
        (["mozzarella"], "mozzarella"),
        (["parmesan", "parmigiano"], "parmesan"),
        (["shredded", "cheddar", "cheese"], "shreddedCheese"),
        (["butter"], "butter"),
        (["heavy cream", "whipping cream", "sour cream", "cream"], "heavyCream"),
        (["milk"], "milk"),
        (["yogurt", "yoghurt"], "yogurt"),
        (["egg"], "eggs"),

        // ── Produce ──────────────────────────────────────────────────────
        (["lemon"], "lemon"),
        (["lime"], "lime"),
        (["garlic"], "garlic"),
        (["onion", "shallot"], "onion"),
        (["tomato"], "tomato"),
        (["bell pepper"], "bellPepper"),
        (["jalapeno", "jalapeño", "serrano", "green chili", "green chile",
          "chili", "chile"], "greenChili"),
        (["potato"], "potato"),
        (["carrot"], "carrot"),
        (["broccoli"], "broccoli"),
        (["spinach"], "spinach"),
        (["mushroom"], "mushroom"),
        (["corn"], "corn"),
        (["avocado"], "avocado"),
        (["ginger"], "ginger"),
        (["cilantro", "coriander"], "cilantro"),
        (["banana"], "banana"),
        (["apple"], "apple"),

        // ── Pantry: grains & staples ─────────────────────────────────────
        (["basmati"], "basmatiRice"),
        (["rice", "risotto"], "rice"),
        (["spaghetti"], "spaghetti"),
        (["pasta", "penne", "macaroni", "noodle", "fettuccine", "linguine",
          "rigatoni", "lasagna"], "pasta"),
        (["flour"], "flour"),
    ]
}
