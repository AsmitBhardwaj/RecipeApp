//
//  GroceryManualItem.swift
//  RecipeKit
//
//  A free-form item the user added to the grocery list by hand (e.g. "milk",
//  "paper towels") — NOT derived from any planned recipe. Unlike recipe-derived
//  line items, this is real persisted content: it can't be re-computed from the
//  meal plan, so its text lives in `GroceryCheckStore` and survives relaunches.
//
//  Each item is scoped to the period it was added under (a specific day or the
//  current week), matching how derived items and their checkmarks are keyed.
//

import Foundation

public struct GroceryManualItem: Codable, Identifiable, Hashable {
    public let id: String
    /// The period this was added under: "day:yyyy-MM-dd" or "week:yyyy-MM-dd".
    public let period: String
    public let name: String
    public let addedAt: Date

    public init(
        id: String = UUID().uuidString,
        period: String,
        name: String,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.period = period
        self.name = name
        self.addedAt = addedAt
    }

    /// Full checked-state key. Already period-scoped (period is stored on the
    /// item), and namespaced with "manual" so a hand-typed "milk" can never
    /// collide with a recipe-derived "milk" line's checkmark.
    public var checkKey: String {
        "\(period)|manual|\(name.lowercased())"
    }
}
