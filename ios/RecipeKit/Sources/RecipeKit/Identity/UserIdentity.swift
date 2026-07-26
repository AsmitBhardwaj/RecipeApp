//
//  UserIdentity.swift
//  RecipeKit
//
//  Anonymous user identity: a UUID generated once on first launch, stored in the
//  shared App Group Keychain so both the app and the Share Extension resolve the
//  same value.
//
//  Public entry point: `RecipeKit.currentUserID`.
//

import Foundation

/// The resolve algorithm, isolated from the concrete Keychain so it can be
/// unit-tested against an in-memory `SecretStore` on the host (a real Keychain
/// access group needs the iOS app-group entitlement, unavailable to host tests).
///
/// Cross-process safety (app + extension may run concurrently): we never blindly
/// overwrite. If our `addIfAbsent` loses the race (`false`), we adopt whatever
/// value actually persisted, so every caller converges on the first writer's ID.
enum Identity {
    static func resolveUserID(in store: SecretStore, account: String) -> String {
        // 1. Fast path: an ID already exists.
        if let existing = try? store.string(forKey: account), let existing, !existing.isEmpty {
            return existing
        }
        // 2. No ID yet — try to be the one who creates it.
        let candidate = UUID().uuidString
        if let didAdd = try? store.addIfAbsent(candidate, forKey: account), didAdd {
            return candidate
        }
        // 3. Someone else added first (or a transient error): adopt the stored value.
        if let persisted = try? store.string(forKey: account), let persisted, !persisted.isEmpty {
            return persisted
        }
        // 4. Keychain genuinely unavailable — return a usable (non-persisted) ID
        //    rather than crash. Next successful launch will persist one.
        return candidate
    }
}

public enum RecipeKit {
    static let keychainService = "com.recipeapp.identity"
    static let userIDAccount = "anonymous_user_id"

    /// Backed by the shared App Group Keychain access group so the value is
    /// readable from the Share Extension.
    static let keychain = KeychainStore(service: keychainService, accessGroup: AppGroup.identifier)

    /// Serializes concurrent access *within a process*. Cross-process races are
    /// handled by the "first writer wins, loser adopts" logic in `Identity`.
    private static let lock = NSLock()

    /// The anonymous user ID. Reads the existing ID if present; otherwise creates,
    /// stores, and returns a new one. Safe to call from either target.
    public static var currentUserID: String {
        lock.lock()
        defer { lock.unlock() }
        return Identity.resolveUserID(in: keychain, account: userIDAccount)
    }
}
