//
//  AppGroup.swift
//  RecipeKit
//
//  The single, shared source of truth for the App Group identifier used by both
//  the main app and the future Share Extension. This same string is:
//    1. listed in each target's `com.apple.security.application-groups` entitlement, and
//    2. used verbatim as the Keychain access group (`kSecAttrAccessGroup`).
//
//  On iOS an app-group identifier is itself a valid Keychain access group for
//  every target entitled to that group — no team-ID prefix required. That is
//  what lets the extension read the exact same anonymous user ID the app wrote.
//
//  If you change this string, change it in BOTH targets' entitlements too, or
//  Keychain reads/writes will fail with errSecMissingEntitlement (-34018).
//

import Foundation

public enum AppGroup {
    public static let identifier = "group.com.recipeapp.shared2"
}
