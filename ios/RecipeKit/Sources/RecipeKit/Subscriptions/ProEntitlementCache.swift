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
    // Per-account keys ("pro_entitled_v2.<accountId>"). The value is the SERVER's
    // entitlement answer for that specific account — NOT device StoreKit state — so
    // it never leaks Pro from a device's Apple ID to an unrelated account.
    private static let prefix = "pro_entitled_v2."

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: AppGroup.identifier)
    }

    /// The last server entitlement cached for `accountId`. Defaults to `false`
    /// (not entitled) when unset, the account is nil, or the App Group is
    /// unavailable, so a free/unknown account never reads as Pro.
    public static func isEntitled(accountId: String?) -> Bool {
        guard let accountId, !accountId.isEmpty, let defaults else { return false }
        return defaults.bool(forKey: prefix + accountId)
    }

    /// Persist the server's entitlement answer for one account, so the UI (and the
    /// Share Extension) can read this account's Pro state synchronously at first
    /// render without a flash of a locked state.
    public static func set(_ entitled: Bool, accountId: String?) {
        guard let accountId, !accountId.isEmpty, let defaults else { return }
        defaults.set(entitled, forKey: prefix + accountId)
    }

    /// Removes ALL per-account cached entitlements. Called on sign-out / account
    /// deletion so a prior account's Pro state can't leak to the next account on
    /// this device. A new sign-in starts from free until the server confirms Pro
    /// for that account.
    public static func clear() {
        guard let defaults else { return }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
