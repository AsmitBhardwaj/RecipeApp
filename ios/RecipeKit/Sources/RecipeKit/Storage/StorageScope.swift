//
//  StorageScope.swift
//  RecipeKit
//
//  Helper for making the local stores account-scoped (Stage 2b). A store's
//  UserDefaults key becomes `<base>_<userId>` when a scope is supplied, so two
//  accounts on one device keep separate data. A nil scope keeps the legacy,
//  un-namespaced key — used by pre-accounts data and the Stage 4 "claim" path.
//

import Foundation

func scopedStorageKey(_ base: String, _ userScope: String?) -> String {
    guard let userScope, !userScope.isEmpty else { return base }
    return "\(base)_\(userScope)"
}
