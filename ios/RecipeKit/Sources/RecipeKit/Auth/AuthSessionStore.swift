//
//  AuthSessionStore.swift
//  RecipeKit
//
//  Persists the signed-in `AuthSession` as JSON in the SHARED App Group Keychain,
//  so the token lives in the same access group the Share Extension can read
//  (Stage 6 keeps the extension anonymous, but the plan requires the token to
//  live in the shared group). Keychain (not UserDefaults) because these are
//  credentials.
//
//  The backing store is abstracted behind `TokenSecretStore` so the round-trip
//  can be unit-tested on the host with an in-memory backend — a real Keychain
//  access group needs the app-group entitlement, unavailable to host tests.
//

import Foundation

/// Minimal read/write/delete over a secret-backed key/value store.
public protocol TokenSecretStore {
    func read(_ account: String) -> String?
    func write(_ value: String, account: String)
    func delete(_ account: String)
}

/// The production backend: the shared App Group Keychain.
public struct KeychainTokenStore: TokenSecretStore {
    private let keychain: KeychainStore

    public init(service: String = "com.recipeapp.auth", accessGroup: String? = AppGroup.identifier) {
        self.keychain = KeychainStore(service: service, accessGroup: accessGroup)
    }

    public func read(_ account: String) -> String? {
        (try? keychain.string(forKey: account)) ?? nil
    }

    public func write(_ value: String, account: String) {
        try? keychain.set(value, forKey: account)
    }

    public func delete(_ account: String) {
        try? keychain.removeValue(forKey: account)
    }
}

/// Loads/saves/clears the single persisted session.
public struct AuthSessionStore {
    private static let account = "auth_session_v1"
    private let backend: TokenSecretStore

    public init(backend: TokenSecretStore = KeychainTokenStore()) {
        self.backend = backend
    }

    public func load() -> AuthSession? {
        guard let json = backend.read(Self.account), let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder.authDecoder.decode(AuthSession.self, from: data)
    }

    public func save(_ session: AuthSession) {
        guard let data = try? JSONEncoder.authEncoder.encode(session),
              let json = String(data: data, encoding: .utf8) else { return }
        backend.write(json, account: Self.account)
    }

    public func clear() {
        backend.delete(Self.account)
    }
}

// Stable ISO-8601 date coding for the persisted session.
extension JSONEncoder {
    static var authEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var authDecoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
