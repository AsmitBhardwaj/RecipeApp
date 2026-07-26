//
//  Diagnostics.swift
//  RecipeKit
//
//  DEBUG-only self-check that proves the App Group Keychain sharing is wired
//  correctly, on the real platform (iOS simulator/device) where the entitlement
//  is actually applied. Not compiled into release builds.
//
//  It models the future Share Extension with an *independent* KeychainStore that
//  knows only the service + shared access group — exactly what the extension
//  will have. If that independent reader sees the same ID the app wrote, and the
//  stored item's access group is the App Group, sharing is proven.
//

#if DEBUG
import Foundation

public enum RecipeKitDiagnostics {

    /// Runs the identity checks and returns a human-readable report. Also returns
    /// an overall pass/fail so a caller can set an exit code.
    public static func identityReport() -> (report: String, passed: Bool) {
        var lines: [String] = []
        var passed = true
        func check(_ label: String, _ condition: Bool) {
            passed = passed && condition
            lines.append("  [\(condition ? "PASS" : "FAIL")] \(label)")
        }

        lines.append("== RecipeKit identity diagnostics ==")
        lines.append("App Group / access group: \(AppGroup.identifier)")

        // Caller A: the app resolving its ID (creates + stores on first run).
        let idA = RecipeKit.currentUserID
        lines.append("Caller A (app) currentUserID:        \(idA)")

        // Same process, second call — must be identical (idempotent).
        let idA2 = RecipeKit.currentUserID
        lines.append("Caller A second read:                \(idA2)")
        check("second call returns the SAME id (idempotent)", idA == idA2)

        // Caller B: an INDEPENDENT reader with only the shared access group —
        // models the Share Extension. No shared in-memory state.
        let extReader = KeychainStore(
            service: RecipeKit.keychainService,
            accessGroup: AppGroup.identifier
        )
        let idB = (try? extReader.string(forKey: RecipeKit.userIDAccount)) ?? nil
        lines.append("Caller B (extension-like) reads:     \(idB ?? "nil")")
        check("independent reader sees the same id", idB == idA)

        // Prove the item lives in the SHARED access group, not the private default.
        let storedGroup = (try? extReader.storedAccessGroup(forKey: RecipeKit.userIDAccount)) ?? nil
        lines.append("Stored item's access group:          \(storedGroup ?? "nil")")
        check("id is stored in the App Group access group", storedGroup == AppGroup.identifier)

        lines.append(passed ? "RESULT: PASS ✅" : "RESULT: FAIL ❌")
        return (lines.joined(separator: "\n"), passed)
    }
}
#endif
