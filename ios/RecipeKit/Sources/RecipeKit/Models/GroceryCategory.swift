//
//  GroceryCategory.swift
//  RecipeKit
//
//  The small, practical set of shopping aisles the grocery list groups by. Order
//  of the `allCases` array IS the display order in the UI (roughly a store walk:
//  fresh first, shelf-stable in the middle, frozen last, catch-all at the end).
//
//  Categorization itself is a free, offline keyword heuristic (`GroceryCategorizer`)
//  — no LLM call. Unknown ingredients fall to `.other` rather than guessing. The
//  seam for a future upgrade is deliberate: if the backend ever populates a
//  per-ingredient category at extraction time, callers can prefer that and use
//  this heuristic only as the fallback.
//

import Foundation

public enum GroceryCategory: String, Codable, CaseIterable, Hashable {
    case produce
    case meatSeafood
    case dairyEggs
    case bakery
    case pantry
    case frozen
    case other

    /// Section title shown in the grocery list.
    public var displayName: String {
        switch self {
        case .produce: return "Produce"
        case .meatSeafood: return "Meat & Seafood"
        case .dairyEggs: return "Dairy & Eggs"
        case .bakery: return "Bakery"
        case .pantry: return "Pantry"
        case .frozen: return "Frozen"
        case .other: return "Other"
        }
    }
}
