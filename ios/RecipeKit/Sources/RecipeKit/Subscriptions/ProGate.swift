//
//  ProGate.swift
//  RecipeKit
//
//  The single, pure decision for whether Pro-gated UI should be UNLOCKED.
//  Kept free of StoreKit and SwiftUI so it is unit-testable and shared by every
//  gate (pantry suggestions, nutrition, …).
//
//  This is a PRESENTATION gate only. It decides what the UI reveals; it is not a
//  security/cost boundary. Anything that must actually be enforced (LLM spend,
//  server data) is gated server-side elsewhere.
//

import Foundation

public enum ProGate {
    /// Whether Pro content should be shown for the SIGNED-IN account.
    ///
    /// - `serverIsPro`: the server-verified entitlement for THIS account
    ///                  (`/v1/entitlements/*`). This is the source of truth.
    /// - `cached`:      the last server result for THIS account, persisted per
    ///                  account in the App Group (`ProEntitlementCache`), used ONLY
    ///                  to avoid a flash of a locked state on cold launch / offline.
    ///
    /// Device StoreKit (`Transaction.currentEntitlements`) is deliberately NOT an
    /// input: it is scoped to the device's Apple ID, so any Platter account signed
    /// in on a device whose Apple ID owns a subscription would otherwise show Pro.
    /// Pro must follow the account that purchased it, per the server.
    public static func isUnlocked(serverIsPro: Bool, cached: Bool) -> Bool {
        serverIsPro || cached
    }

    /// The paywall "restore" edge case: the device's Apple ID already owns Platter
    /// Pro, but the signed-in account is NOT entitled server-side. Show a "Restore
    /// to this account" flow instead of a Subscribe CTA that would fail with
    /// "already subscribed".
    public static func needsRestore(deviceHasEntitlement: Bool, serverIsPro: Bool) -> Bool {
        deviceHasEntitlement && !serverIsPro
    }
}
