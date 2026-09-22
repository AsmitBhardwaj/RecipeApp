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
    /// Whether Pro content should be shown.
    ///
    /// - `live`:   the verified StoreKit entitlement grant. It is briefly `false`
    ///             on cold launch while entitlement is still loading (`.unknown`).
    /// - `cached`: the last known entitlement persisted to the App Group
    ///             (`ProEntitlementCache`), available synchronously at first render.
    ///
    /// Returning `live || cached` means a returning Pro user sees content
    /// immediately — no flash of a locked state before the StoreKit refresh
    /// resolves — while a purchase made in-session unlocks live via `live`.
    public static func isUnlocked(live: Bool, cached: Bool) -> Bool {
        live || cached
    }
}
