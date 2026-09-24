//
//  ProEntitlementCache.swift
//  RecipeKit
//
//  A tiny App-Group-shared cache of the user's Pro entitlement, written by the
//  main app (from verified StoreKit state) and read by any target that needs to
//  tell the backend "this user is Pro" — notably the Share Extension, which
//  cannot query StoreKit itself.
//
//  This is a CONVENIENCE CLAIM, not a source of truth:
//    * Gating actual Pro FEATURES must use verified StoreKit state
//      (`ProEntitlementState.grantsAccess`), never this flag.
//    * Its ONLY consumer is the `X-Pro-Entitled` request header, which merely
//      waives the free-import limit server-side. The backend cannot verify Pro
//      anyway, so a stale/forged value costs only cheap LLM calls (still bounded
//      by the per-user/IP rate limiter) — the deliberate "smallest safe version"
//      trade-off.
//
//  Stored in the App Group `UserDefaults` (not the keychain): it is not a
//  credential, and it must be reachable from the extension. All access is
//  best-effort and safe when the suite is unavailable.
//

import Foundation

public enum ProEntitlementCache {
    private static let key = "pro_entitled_v1"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: AppGroup.identifier)
    }

    /// The last entitlement the app cached. Defaults to `false` (not entitled)
    /// when unset or the App Group is unavailable, so a free user never
    /// accidentally sends a Pro claim.
    public static var isEntitled: Bool {
        defaults?.bool(forKey: key) ?? false
    }

    /// Called by the app whenever verified entitlement changes, so the extension
    /// sees the current value on its next run.
    public static func set(_ entitled: Bool) {
        defaults?.set(entitled, forKey: key)
    }

    /// Removes the cached claim entirely (`isEntitled` reverts to `false`). Called
    /// on sign-out / account deletion so a prior account's Pro claim can't leak to
    /// the next account on this device. The app re-derives verified StoreKit state
    /// (Apple-ID-scoped) immediately afterwards, which restores the claim if that
    /// Apple ID still owns an active subscription.
    public static func clear() {
        defaults?.removeObject(forKey: key)
    }
}
