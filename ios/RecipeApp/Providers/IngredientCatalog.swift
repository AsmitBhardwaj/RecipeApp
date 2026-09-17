//
//  IngredientCatalog.swift
//  RecipeApp
//
//  Bundled, static autocomplete source for the "Add to kitchen" sheet. Loads a
//  few hundred common pantry/grocery names from `PantryIngredients.json` (in the
//  app bundle — NO network call) once, then answers case-insensitive prefix
//  queries for the type-ahead list.
//
//  This is purely a UI convenience / data source. It does NOT touch how items
//  get added to the pantry (`PantryModel.add` still stores whatever text the
//  user submits, catalog hit or free text alike).
//

import Foundation

struct IngredientCatalog {
    /// Shared instance — the JSON is small and loaded once at first use.
    static let shared = IngredientCatalog()

    /// All catalog names, lowercased, sorted, de-duplicated.
    let names: [String]

    /// Loads from the app bundle. Falls back to an empty catalog if the resource
    /// is missing or malformed, so a bad build degrades to "free text only"
    /// rather than crashing.
    init(bundle: Bundle = .main, resource: String = "PantryIngredients") {
        guard
            let url = bundle.url(forResource: resource, withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let raw = try? JSONDecoder().decode([String].self, from: data)
        else {
            names = []
            return
        }
        let cleaned = Set(raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
            .filter { !$0.isEmpty }
        names = cleaned.sorted()
    }

    /// Test seam: build a catalog from an explicit list (bypasses the bundle).
    init(names: [String]) {
        self.names = Set(names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
            .filter { !$0.isEmpty }
            .sorted()
    }

    /// Case-insensitive PREFIX matches for `query`, capped at `limit`.
    ///
    /// Empty/whitespace query returns nothing (the sheet shows no list until the
    /// user starts typing, and never blocks free-text entry).
    func matches(prefix query: String, limit: Int = 6) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        var out: [String] = []
        for name in names where name.hasPrefix(needle) {
            // Skip an exact-and-only match — no point suggesting what's already typed.
            if name == needle { continue }
            out.append(name)
            if out.count == limit { break }
        }
        return out
    }
}
