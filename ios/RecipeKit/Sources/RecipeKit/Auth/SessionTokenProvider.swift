//
//  SessionTokenProvider.swift
//  RecipeKit
//
//  Resolves a currently-valid access token from the SHARED App Group session,
//  refreshing it first when it is at/near expiry. This is what lets BOTH the main
//  app and the Share Extension attach a fresh `Authorization: Bearer` on the
//  now-authenticated import/paste endpoints — the extension has no `AuthModel`, so
//  without this it would only ever send whatever (often long-expired, 30-min TTL)
//  access token happened to be on disk.
//
//  It reads/writes the same `AuthSessionStore` the app's `AuthModel` uses, so a
//  refresh performed here is visible to the app and vice-versa.
//

import Foundation

/// Reads the shared session and hands back a valid access token, refreshing on
/// the fly. Stateless and cheap to construct per call.
public struct SessionTokenProvider {
    private let store: AuthSessionStore
    private let api: AuthAPI

    public init(store: AuthSessionStore = AuthSessionStore(), api: AuthAPI = AuthAPI()) {
        self.store = store
        self.api = api
    }

    /// True when a session exists on disk at all (signed in, regardless of whether
    /// the access token is currently fresh). A cheap, network-free check the Share
    /// Extension uses to decide between "submit" and "ask the user to sign in".
    public var hasSession: Bool {
        store.load() != nil
    }

    /// A currently-valid access token, refreshing first when it is within the
    /// leeway of expiring.
    ///
    /// Throws `AuthError.invalidCredentials` when there is no session, or when the
    /// refresh token is itself rejected (expired/revoked) — in which case the local
    /// session is cleared, since it can no longer mint tokens. A *transient* refresh
    /// failure (offline/timeout/5xx) propagates its own `AuthError` WITHOUT clearing
    /// the session, so a network blip never signs the user out.
    public func validAccessToken(now: Date = Date()) async throws -> String {
        guard let session = store.load() else {
            throw AuthError.invalidCredentials
        }
        guard session.accessTokenExpiring(now: now) else {
            return session.accessToken
        }
        do {
            let refreshed = try await api.refresh(refreshToken: session.refreshToken)
            store.save(refreshed)
            return refreshed.accessToken
        } catch AuthError.invalidCredentials {
            // The refresh token is dead — the session is unusable, so drop it so the
            // UI routes to sign-in rather than retrying a doomed refresh forever.
            store.clear()
            throw AuthError.invalidCredentials
        }
        // Any other AuthError (offline/timedOut/server) propagates unchanged; the
        // session stays put so a later attempt can still succeed.
    }

    /// Convenience for header assembly: the valid access token, or nil on any
    /// failure. Callers that need to distinguish "signed out" from "couldn't
    /// refresh right now" should use `validAccessToken()` and inspect the error.
    public func accessTokenOrNil() async -> String? {
        try? await validAccessToken()
    }
}
