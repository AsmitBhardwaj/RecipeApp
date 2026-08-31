//
//  KeychainStore.swift
//  RecipeKit
//
//  A minimal wrapper over the Security framework's generic-password Keychain,
//  scoped to a service and an optional access group. When an access group is
//  supplied it is set as `kSecAttrAccessGroup`, which is what makes items
//  readable across targets that share that group (app + Share Extension).
//
//  Items are stored `kSecAttrAccessibleAfterFirstUnlock` so a background-launched
//  extension can read the user ID even while the device is locked.
//

import Foundation
import Security

/// The narrow behavior identity resolution needs — abstracted so the resolve
/// algorithm can be unit-tested against an in-memory store on the host, without
/// the iOS app-group entitlement that a real Keychain access group requires.
protocol SecretStore {
    func string(forKey account: String) throws -> String?
    /// Adds the value only if no item exists yet. Returns `true` if this call
    /// created the item, `false` if one already existed (someone else won).
    func addIfAbsent(_ value: String, forKey account: String) throws -> Bool
}

struct KeychainStore {
    let service: String
    let accessGroup: String?

    init(service: String, accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    enum KeychainError: Error, CustomStringConvertible {
        case unexpectedStatus(OSStatus)

        var description: String {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
                return "Keychain OSStatus \(status): \(message)"
            }
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Only include the access group when set. Passing an access group the
        // process isn't entitled to fails with errSecMissingEntitlement, so a
        // nil group intentionally falls back to the app's private Keychain.
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    func string(forKey account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                return nil
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func addIfAbsent(_ value: String, forKey account: String) throws -> Bool {
        var query = baseQuery(account: account)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return true
        case errSecDuplicateItem:
            return false
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Upserts a value (unlike `addIfAbsent`, which no-ops when one exists).
    /// Used for credentials that rotate, e.g. the auth session on token refresh.
    func set(_ value: String, forKey account: String) throws {
        let attributes = [kSecValueData as String: Data(value.utf8)]
        let updateStatus = SecItemUpdate(baseQuery(account: account) as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var query = baseQuery(account: account)
            query[kSecValueData as String] = Data(value.utf8)
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        default:
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    func removeValue(forKey account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Reads back the access group the stored item actually lives in. Used only
    /// by diagnostics to prove the item is in the shared App Group group and not
    /// the app's private default group.
    func storedAccessGroup(forKey account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return (item as? [String: Any])?[kSecAttrAccessGroup as String] as? String
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

extension KeychainStore: SecretStore {}
