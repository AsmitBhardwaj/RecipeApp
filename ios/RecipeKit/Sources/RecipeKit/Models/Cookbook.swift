//
//  Cookbook.swift
//  RecipeKit
//
//  A user-created named collection of recipes. Membership is many-to-many and
//  lives OUTSIDE this model, in `CookbookMembershipStore` — a recipe can belong
//  to several cookbooks and stays an immutable, shared/cached value type.
//
//  The "All Recipes" collection is NOT a `Cookbook` value: it's a synthetic,
//  always-present view the UI prepends, so it can never be renamed or deleted.
//

import Foundation

public struct Cookbook: Codable, Identifiable, Hashable {
    public let id: String
    /// User-facing name. Mutable so a cookbook can be renamed (persisted via
    /// `CookbookStore.upsert`).
    public var name: String
    public let createdAt: Date

    public init(id: String = UUID().uuidString, name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}
