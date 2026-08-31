//
//  SyncModels.swift
//  RecipeKit
//
//  The client-side shapes for the account-scoped sync API (Stage 2b), matching
//  the backend contract in app/sync.py. `SyncChange` is the unit of sync — one
//  record in one collection — and doubles as the on-the-wire and in-outbox
//  representation. `updatedAt` is epoch MILLISECONDS (the last-writer-wins key);
//  `payload` is opaque JSON the app owns; `seq` is the server-assigned version,
//  present only on records the server returns.
//

import Foundation

/// The synced collections. Raw values are the backend's collection names.
public enum SyncCollection: String, CaseIterable, Codable, Sendable {
    case library
    case mealPlan = "meal_plan"
    case groceryCheck = "grocery_check"
    case groceryManual = "grocery_manual"
    case cookbook
    case cookbookMembership = "cookbook_membership"
}

public struct SyncChange: Codable, Equatable, Sendable {
    public let collection: SyncCollection
    public let itemId: String
    public var updatedAt: Int64
    public var deleted: Bool
    public var payload: String?
    /// Server-assigned version; nil for a locally-originated change.
    public var seq: Int64?

    public init(collection: SyncCollection, itemId: String, updatedAt: Int64,
                deleted: Bool = false, payload: String? = nil, seq: Int64? = nil) {
        self.collection = collection
        self.itemId = itemId
        self.updatedAt = updatedAt
        self.deleted = deleted
        self.payload = payload
        self.seq = seq
    }

    enum CodingKeys: String, CodingKey {
        case collection
        case itemId = "item_id"
        case updatedAt = "updated_at"
        case deleted
        case payload
        case seq
    }
}

/// Result of a push: which item ids the server accepted, the records where the
/// server's copy won (the client should adopt these), and the user's new cursor.
public struct SyncPushResult: Equatable, Sendable {
    public let applied: [String]
    public let conflicts: [SyncChange]
    public let cursor: Int64
}

/// Result of a pull: the changes since the requested cursor, the new cursor, and
/// whether more remain beyond the page.
public struct SyncPullResult: Equatable, Sendable {
    public let changes: [SyncChange]
    public let cursor: Int64
    public let hasMore: Bool
}

public enum SyncError: Error, Equatable, Sendable {
    case unauthorized          // 401 — token invalid/expired; caller should re-auth
    case offline
    case timedOut
    case server(Int)
    case invalidResponse(String)
}

/// Current epoch time in milliseconds — the stamp for a local mutation.
public func syncNowMillis(_ date: Date = Date()) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1000).rounded())
}
