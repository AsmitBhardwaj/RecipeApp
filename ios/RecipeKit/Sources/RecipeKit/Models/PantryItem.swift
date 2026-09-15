//
//  PantryItem.swift
//  RecipeKit
//
//  One thing the user has in their kitchen ("the pantry") — a deliberately bare
//  name entry. Modeled on `GroceryManualItem` but stripped to the essentials:
//  there is NO checked/bought state (removing an item IS "used it up"), no
//  period scoping (the pantry is one persistent list, not day/week buckets), and
//  no quantity/unit/expiration/category — v1 is just a name list.
//
//  `name` is stored EXACTLY as the user typed it. No normalization happens at
//  write time; that belongs to the (separate, later) suggestion/match feature,
//  which normalizes at match time so the user always sees their own words back.
//
//  Rides the generic sync architecture as the `pantry_items` collection: one
//  record per item, keyed by `id`, payload = this struct. `dateAdded` round-trips
//  exactly under `SyncCodec` (`.secondsSince1970`).
//

import Foundation

public struct PantryItem: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    /// The item's name, verbatim as the user typed it (no normalization).
    public let name: String
    public let dateAdded: Date

    public init(
        id: UUID = UUID(),
        name: String,
        dateAdded: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.dateAdded = dateAdded
    }
}
