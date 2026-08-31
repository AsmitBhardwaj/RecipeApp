//
//  GroceryItemEmoji.swift
//  RecipeKit
//
//  Picks a small food emoji for an INDIVIDUAL grocery item, shown in place of the
//  plain checkbox circle on the Grocery List.
//
//  This is a dedicated, self-contained ingredient dictionary — deliberately NOT
//  the 11-way `RecipeImageCategory` dish system, which classifies whole dishes by
//  dominant protein and produces meaningless matches for raw ingredients (lemon
//  juice, onion, salt). It also does NOT depend on the item's `GroceryCategory`
//  aisle, so every item gets an icon for what it actually IS, never one inherited
//  from the section it's grouped under.
//
//  Matching: the item name is lowercased and tested against `table` IN ORDER;
//  the first entry with a matching substring wins. Order therefore encodes
//  specificity — compound/qualified terms ("garlic powder", "bell pepper",
//  "sweet potato", "eggplant") sit ABOVE the generic word they contain
//  ("garlic", "pepper", "potato", "egg"). Edit freely; keep specific-before-
//  generic when adding.
//

import Foundation

public enum GroceryItemEmoji {

    /// Emoji for a grocery item, matched on its name alone. `aisle` is accepted
    /// for source-compat but unused — categorization here is purely name-based.
    public static func emoji(for name: String, aisle: GroceryCategory? = nil) -> String {
        let n = name.lowercased()
        for entry in table where entry.keywords.contains(where: { n.contains($0) }) {
            return entry.emoji
        }
        return "🛒" // neutral fallback for anything unrecognized
    }

    /// (keywords, emoji) in match-priority order. EARLIER ENTRIES WIN.
    private static let table: [(keywords: [String], emoji: String)] = [

        // ── Spice powders / flakes / leaveners ─ must beat the raw produce and
        //    protein words they contain (e.g. "garlic powder" ≠ 🧄). All → 🧂.
        (["garlic powder", "onion powder", "chili powder", "curry powder",
          "pepper flake", "red pepper", "chili flake", "cornstarch",
          "baking soda", "baking powder", "cream of tartar"], "🧂"),

        // ── Stock/broth ─ before proteins so "chicken broth" ≠ 🍗.
        (["broth", "stock", "bouillon"], "🥫"),

        // ── Compound overrides ─ before the generic word each contains.
        (["sweet potato"], "🍠"),
        (["bell pepper"], "🫑"),
        (["cream cheese"], "🧀"),
        (["coconut milk", "coconut"], "🥥"),
        (["peanut butter"], "🫙"),
        (["butternut"], "🎃"),
        (["ice cream"], "🍨"),
        (["olive oil", "olive"], "🫒"),
        (["sesame oil"], "🫗"),
        (["eggplant"], "🍆"),

        // ── Meat & Seafood ───────────────────────────────────────────────
        (["chicken", "turkey", "poultry"], "🍗"),
        (["beef", "steak", "brisket", "meatball", "burger", "mince"], "🥩"),
        (["pork", "bacon", "sausage", "prosciutto", "pancetta", "chorizo",
          "pepperoni", " ham", "ham ", "ham,"], "🥓"),
        (["lamb"], "🍖"),
        (["shrimp", "prawn"], "🦐"),
        (["crab"], "🦀"),
        (["lobster"], "🦞"),
        (["scallop", "clam", "mussel", "oyster"], "🦪"),
        (["squid", "calamari"], "🦑"),
        (["salmon", "tuna", "cod", "tilapia", "halibut", "trout", "anchovy",
          "fish"], "🐟"),

        // ── Dairy & Eggs ─────────────────────────────────────────────────
        (["cheese", "parmesan", "parmigiano", "mozzarella", "cheddar", "feta",
          "ricotta", "mascarpone", "gouda", "brie"], "🧀"),
        (["butter"], "🧈"),
        (["milk", "cream", "yogurt", "yoghurt", "buttermilk"], "🥛"),
        (["egg"], "🥚"),

        // ── Produce: vegetables & aromatics ──────────────────────────────
        (["lemon", "lime"], "🍋"),
        (["onion", "scallion", "shallot", "leek"], "🧅"),
        (["garlic"], "🧄"),
        (["tomato"], "🍅"),
        (["jalapeno", "jalapeño", "chili", "chile", "chilli"], "🌶️"),
        (["potato"], "🥔"),
        (["carrot"], "🥕"),
        (["broccoli", "cauliflower"], "🥦"),
        (["lettuce", "spinach", "kale", "arugula", "cabbage", "greens",
          "chard", "bok choy"], "🥬"),
        (["cucumber", "pickle"], "🥒"),
        (["avocado"], "🥑"),
        (["mushroom"], "🍄"),
        (["corn"], "🌽"),
        (["ginger"], "🫚"),
        (["basil", "cilantro", "parsley", "mint", "thyme", "rosemary", "dill",
          "sage", "oregano", "herb"], "🌿"),
        (["pea", "green bean", "edamame"], "🫛"),

        // ── Produce: fruit ───────────────────────────────────────────────
        (["apple"], "🍎"),
        (["banana"], "🍌"),
        (["strawberr", "raspberr", "berry", "berries"], "🍓"),
        (["blueberr"], "🫐"),
        (["grape"], "🍇"),
        (["orange", "clementine", "mandarin"], "🍊"),
        (["mango"], "🥭"),
        (["pineapple"], "🍍"),
        (["peach", "nectarine", "apricot"], "🍑"),
        (["pear"], "🍐"),
        (["watermelon", "melon", "cantaloupe"], "🍉"),
        (["cherry", "cherries"], "🍒"),
        (["coconut"], "🥥"),

        // ── Bakery ───────────────────────────────────────────────────────
        (["croissant"], "🥐"),
        (["bread", "dough", "bun", "bagel", "tortilla", "baguette", "roll",
          "pita", "naan", "brioche", "loaf", "ciabatta", "focaccia",
          "sourdough"], "🍞"),

        // ── Pantry: grains, staples, canned, condiments, sweeteners ──────
        (["rice", "risotto", "quinoa", "couscous"], "🍚"),
        (["pasta", "spaghetti", "noodle", "macaroni", "penne", "lasagna",
          "fettuccine", "linguine", "ravioli", "gnocchi", "orzo", "ramen"], "🍝"),
        (["flour"], "🌾"),
        (["oats", "oatmeal", "granola"], "🥣"),
        (["bean", "chickpea", "lentil"], "🫘"),
        (["canned", "can of"], "🥫"),
        (["soy sauce", "fish sauce", "hot sauce", "worcestershire", "ketchup",
          "mustard", "mayo", "sauce", "vinegar", "jam", "jelly", "vanilla",
          "extract"], "🫙"),
        (["oil"], "🫗"),
        (["honey", "syrup", "maple", "molasses", "agave"], "🍯"),
        (["sugar"], "🍬"),
        (["chocolate", "cocoa", "chip"], "🍫"),
        (["almond", "walnut", "pecan", "cashew", "pistachio", "hazelnut",
          "peanut", "sesame", "seed", "nut"], "🥜"),
        (["coffee", "espresso"], "☕"),
        (["tea"], "🍵"),
        (["wine"], "🍷"),
        (["ice cream", "sorbet", "gelato"], "🍨"),
        (["frozen"], "🧊"),

        // ── Spices / seasonings ─ neutral shaker (salt gets it too). ──────
        (["salt", "pepper", "peppercorn", "cayenne", "paprika", "cumin",
          "cinnamon", "nutmeg", "turmeric", "coriander", "cardamom", "clove",
          "spice", "seasoning", "yeast"], "🧂"),
    ]
}
