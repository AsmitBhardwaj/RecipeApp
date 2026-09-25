//
//  AccountUUID.swift
//  RecipeApp
//
//  Converts a Platter account id into a `UUID` for StoreKit's `appAccountToken`.
//  Backend account ids are `uuid4().hex` (32 hex chars, no hyphens); StoreKit
//  requires a real `UUID`. The bytes are preserved so the server's normalized
//  comparison (uuid.UUID(appAccountToken) == uuid.UUID(user.id)) matches.
//

import Foundation

enum AccountUUID {
    /// A `UUID` with the same 128 bits as the account id, or nil if the id isn't
    /// UUID-shaped (already-hyphenated ids are accepted directly).
    static func from(_ accountId: String) -> UUID? {
        if let direct = UUID(uuidString: accountId) {
            return direct
        }
        let hex = accountId.replacingOccurrences(of: "-", with: "").lowercased()
        guard hex.count == 32, hex.allSatisfy(\.isHexDigit) else { return nil }
        let g = Array(hex)
        func slice(_ start: Int, _ count: Int) -> String { String(g[start..<start + count]) }
        let canonical = "\(slice(0, 8))-\(slice(8, 4))-\(slice(12, 4))-\(slice(16, 4))-\(slice(20, 12))"
        return UUID(uuidString: canonical)
    }
}
