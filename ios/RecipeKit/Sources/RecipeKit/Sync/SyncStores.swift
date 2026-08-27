//
//  SyncStores.swift
//  RecipeKit
//
//  Account-scoped local persistence for the sync engine:
//   • SyncOutbox      — the queue of local mutations not yet acknowledged by the
//                       server. One entry per (collection, item_id); a newer
//                       local edit supersedes an older queued one.
//   • SyncCursorStore — the last server `seq` this account has pulled, so the
//                       next pull is a delta.
//
//  Both live in the App Group `UserDefaults` under a key namespaced by user id,
//  so two accounts on one device never see each other's queue/cursor. A test
//  seam accepts an injected `UserDefaults`.
//

import Foundation

// MARK: - Outbox

public struct SyncOutbox {
    private let defaults: UserDefaults
    private let key: String

    public init(userId: String, suiteName: String = AppGroup.identifier) {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
        self.key = "sync_outbox_v1_\(userId)"
    }

    public init(userId: String, defaults: UserDefaults) {
        self.defaults = defaults
        self.key = "sync_outbox_v1_\(userId)"
    }

    /// Pending changes in enqueue order (stable, so the server assigns seq in a
    /// predictable order).
    public func pending() -> [SyncChange] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SyncChange].self, from: data)) ?? []
    }

    /// Queue a local mutation. If one already exists for the same
    /// (collection, item_id), the newer `updatedAt` wins and keeps its original
    /// queue position; a stale re-enqueue is ignored.
    public func enqueue(_ change: SyncChange) {
        var items = pending()
        if let idx = items.firstIndex(where: { $0.collection == change.collection && $0.itemId == change.itemId }) {
            if change.updatedAt >= items[idx].updatedAt {
                items[idx] = change
            }
        } else {
            items.append(change)
        }
        write(items)
    }

    /// After a push, drop every entry we SENT that the server has now resolved
    /// (accepted or overruled) — unless a newer local edit arrived meanwhile
    /// (its `updatedAt` will differ from what we sent), which stays queued.
    public func resolve(sent: [SyncChange]) {
        var sentUpdatedAt: [String: Int64] = [:]
        for change in sent {
            sentUpdatedAt[Self.pairKey(change)] = change.updatedAt
        }
        let remaining = pending().filter { current in
            guard let updatedAt = sentUpdatedAt[Self.pairKey(current)] else { return true }
            return current.updatedAt != updatedAt  // superseded since send → keep
        }
        write(remaining)
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }

    private static func pairKey(_ change: SyncChange) -> String {
        "\(change.collection.rawValue)|\(change.itemId)"
    }

    private func write(_ items: [SyncChange]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: key)
    }
}

// MARK: - Cursor

public struct SyncCursorStore {
    private let defaults: UserDefaults
    private let key: String

    public init(userId: String, suiteName: String = AppGroup.identifier) {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
        self.key = "sync_cursor_v1_\(userId)"
    }

    public init(userId: String, defaults: UserDefaults) {
        self.defaults = defaults
        self.key = "sync_cursor_v1_\(userId)"
    }

    public func cursor() -> Int64 {
        Int64(defaults.integer(forKey: key))
    }

    public func setCursor(_ value: Int64) {
        defaults.set(Int(value), forKey: key)
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }
}
