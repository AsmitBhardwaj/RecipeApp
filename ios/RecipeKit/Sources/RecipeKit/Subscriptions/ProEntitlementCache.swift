//
//  ProEntitlementCache.swift
//  RecipeKit
//
//  A tiny App-Group-shared cache of the user's Pro entitlement, written by the
//  main app from verified StoreKit state.
//
//  This is a UI CONVENIENCE, not a source of truth and NOT an API credential:
//    * Gating actual Pro FEATURES on the client uses verified StoreKit state
//      (`ProEntitlementState.grantsAccess`); this flag only lets the UI avoid a
//      flash of a locked state on cold launch (see `ProGate`).
//    * Server-side Pro access is gated by the Apple-verified entitlement stored
//      per account (posted via `/v1/entitlements/verify`) — this flag is NEVER
//      sent to the backend. (Historically it fed an `X-Pro-Entitled` header;
//      that spoofable header has been removed entirely.)
//
//  Stored in the App Group `UserDefaults` (not the keychain): it is not a
//  credential, and it is shared with the extension for the same no-flash UI
//  reason. All access is best-effort and safe when the suite is unavailable.
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
