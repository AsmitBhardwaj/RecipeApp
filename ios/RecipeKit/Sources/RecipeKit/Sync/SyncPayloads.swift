//
//  SyncPayloads.swift
//  RecipeKit
//
//  The per-collection codecs: how each local model maps to a `SyncChange`
//  `payload` (opaque JSON to the server) and back. Models that are already
//  Codable (MealPlanEntry, GroceryManualItem, Cookbook) round-trip directly;
//  the collections that aren't a single model (a grocery check flag, a
//  cookbook↔recipe membership, a library entry) get purpose-built payloads here.
//
//  itemId conventions (stable within a collection):
//    meal_plan          → MealPlanEntry.id
//    grocery_manual     → GroceryManualItem.id
//    grocery_check      → the full check key ("period|itemKey")
//    cookbook           → Cookbook.id
//    cookbook_membership→ "<cookbookId>|<recipeId>"
//    library            → recipeId
//

import Foundation

/// grocery_check payload — whether a check key is currently ticked.
public struct GroceryCheckPayload: Codable, Equatable, Sendable {
    public var checked: Bool
    public init(checked: Bool) { self.checked = checked }
}

/// cookbook_membership payload — one cookbook↔recipe link.
public struct MembershipPayload: Codable, Equatable, Sendable {
    public var cookbookId: String
    public var recipeId: String
    public init(cookbookId: String, recipeId: String) {
        self.cookbookId = cookbookId
        self.recipeId = recipeId
    }
    public static func itemId(cookbookId: String, recipeId: String) -> String {
        "\(cookbookId)|\(recipeId)"
    }
}

/// library payload — membership + light personalization. Recipe CONTENT is not
/// carried here; a new device hydrates bodies via SyncClient.recipes(ids:).
public struct LibraryPayload: Codable, Equatable, Sendable {
    public var recipeId: String
    public var savedAt: String?
    public init(recipeId: String, savedAt: String? = nil) {
        self.recipeId = recipeId
        self.savedAt = savedAt
    }
}

/// Shared JSON coding for sync payloads. Dates use `secondsSince1970` so
/// Date-bearing models (addedAt, createdAt) round-trip EXACTLY — ISO-8601 would
/// truncate sub-second precision and break equality on the way back.
public enum SyncCodec {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    /// Encode a model to a payload string.
    public static func encode<T: Encodable>(_ value: T) -> String? {
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decode a payload string back to a model.
    public static func decode<T: Decodable>(_ type: T.Type, from payload: String?) -> T? {
        guard let payload, let data = payload.data(using: .utf8) else { return nil }
        return try? decoder.decode(type, from: data)
    }
}
