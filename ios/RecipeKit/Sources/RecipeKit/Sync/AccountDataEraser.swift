//
//  AccountDataEraser.swift
//  RecipeKit
//
//  Stage 5 — removes every UserDefaults key scoped to one account from the shared
//  App Group container. Called on in-app account deletion (after the server-side
//  delete succeeds) so the deleted user's recipes, lists, cookbooks, and sync
//  bookkeeping don't linger on the device or leak into the next account.
//
//  Only account-scoped keys are touched. Device-global keys (onboarding flag,
//  appearance, the one-time legacy-claim flag, the un-scoped pending-jobs queue)
//  are intentionally left alone.
//

import Foundation

public enum AccountDataEraser {
    /// Base keys that become `<base>_<userId>` when account-scoped (Stage 2b).
    private static let scopedBaseKeys = [
        "recipes_v1",
        "meal_plan_entries_v1",
        "grocery_checked_keys_v1",
        "grocery_manual_items_v1",
        "cookbooks_v1",
        "cookbook_membership_v1",
        "sync_outbox_v1",
        "sync_cursor_v1",
        "sync_meta_v1",
    ]

    public static func erase(userId: String, suiteName: String = AppGroup.identifier) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        erase(userId: userId, defaults: defaults)
    }

    /// Test/seam: erase from an injected `UserDefaults`.
    public static func erase(userId: String, defaults: UserDefaults) {
        for base in scopedBaseKeys {
            defaults.removeObject(forKey: scopedStorageKey(base, userId))
        }
    }
}
