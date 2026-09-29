//
//  ImportTipStore.swift
//  RecipeKit
//
//  Per-account record of whether the "Save recipes from anywhere" import tip on
//  the Recipes tab was dismissed. Dismissal is permanent for that account.
//

import Foundation

public struct ImportTipStore {
    private static let baseKey = "import_tip_dismissed_v1"
    private let defaults: UserDefaults
    private let storageKey: String

    public init(suiteName: String = AppGroup.identifier, userScope: String?) {
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
        storageKey = scopedStorageKey(Self.baseKey, userScope)
    }

    public init(defaults: UserDefaults, userScope: String?) {
        self.defaults = defaults
        storageKey = scopedStorageKey(Self.baseKey, userScope)
    }

    public var isDismissed: Bool { defaults.bool(forKey: storageKey) }
    public func dismiss() { defaults.set(true, forKey: storageKey) }
}
