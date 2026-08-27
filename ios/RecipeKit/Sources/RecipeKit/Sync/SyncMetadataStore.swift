//
//  SyncMetadataStore.swift
//  RecipeKit
//
//  A small account-scoped map of `collection|itemId → updatedAt` (epoch ms).
//  This is the deliberate alternative to putting an `updatedAt` field on every
//  model: the existing models/stores stay untouched, and last-writer-wins on
//  APPLY (ignore a remote change older than what we hold) plus the timestamp for
//  a local mutation both read/write this side map instead.
//

import Foundation

public struct SyncMetadataStore {
    private let defaults: UserDefaults
    private let key: String

    public init(userId: String, suiteName: String = AppGroup.identifier) {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
        self.key = "sync_meta_v1_\(userId)"
    }

    public init(userId: String, defaults: UserDefaults) {
        self.defaults = defaults
        self.key = "sync_meta_v1_\(userId)"
    }

    public func updatedAt(_ collection: SyncCollection, _ itemId: String) -> Int64? {
        map()[Self.itemKey(collection, itemId)]
    }

    public func setUpdatedAt(_ collection: SyncCollection, _ itemId: String, _ updatedAt: Int64) {
        var m = map()
        m[Self.itemKey(collection, itemId)] = updatedAt
        write(m)
    }

    public func remove(_ collection: SyncCollection, _ itemId: String) {
        var m = map()
        m[Self.itemKey(collection, itemId)] = nil
        write(m)
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }

    private static func itemKey(_ collection: SyncCollection, _ itemId: String) -> String {
        "\(collection.rawValue)|\(itemId)"
    }

    private func map() -> [String: Int64] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: Int64].self, from: data)) ?? [:]
    }

    private func write(_ m: [String: Int64]) {
        guard let data = try? JSONEncoder().encode(m) else { return }
        defaults.set(data, forKey: key)
    }
}
