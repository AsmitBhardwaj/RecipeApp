//
//  AuthModel.swift
//  RecipeApp
//
//  The app-wide auth session (Stage 3). Wraps RecipeKit's `AuthAPI` +
//  `AuthSessionStore`, publishes signed-in state to the UI, persists the session
//  in the shared Keychain, and refreshes the access token silently.
//
//  `validAccessToken()` is the seam Stage 2b's sync engine will call to attach a
//  Bearer token to authenticated requests — refreshing transparently, and
//  signing the user out if the refresh token itself has expired/been revoked.
//

import Foundation
import RecipeKit

@MainActor
final class AuthModel: ObservableObject {
    @Published private(set) var session: AuthSession?
    /// True while a sign-in/register call is in flight (drives button spinners).
    @Published var isWorking = false

    private let api: AuthAPI
    private let store: AuthSessionStore

    init(api: AuthAPI = AuthAPI(), store: AuthSessionStore = AuthSessionStore()) {
        self.api = api
        self.store = store
        self.session = store.load()
    }

    var isSignedIn: Bool { session != nil }
    var currentUser: AuthUser? { session?.user }

    // MARK: - Sign-in / registration

    func register(email: String, password: String, fullName: String?) async throws {
        try await apply { try await self.api.register(email: email, password: password, fullName: fullName) }
    }

    func login(email: String, password: String) async throws {
        try await apply { try await self.api.login(email: email, password: password) }
    }

    func signInWithApple(identityToken: String, fullName: String?) async throws {
        try await apply { try await self.api.apple(identityToken: identityToken, fullName: fullName) }
    }

    func signInWithGoogle(idToken: String, fullName: String?) async throws {
        try await apply { try await self.api.google(idToken: idToken, fullName: fullName) }
    }

    private func apply(_ op: @escaping () async throws -> AuthSession) async throws {
        isWorking = true
        defer { isWorking = false }
        let session = try await op()
        self.session = session
        store.save(session)
    }

    // MARK: - Sign out

    func signOut() {
        if let refresh = session?.refreshToken {
            Task { await api.logout(refreshToken: refresh) }
        }
        clearLocalSession()
    }

    private func clearLocalSession() {
        session = nil
        store.clear()
    }

    // MARK: - Account deletion (Stage 5)

    /// Irreversibly delete the account server-side, then wipe this device's local
    /// copy of its data and sign out. Throws (leaving the user signed in) if the
    /// server delete fails, so we never erase local data against a delete that
    /// didn't happen. On success `session` becomes nil and RootView routes to
    /// the sign-in screen.
    func deleteAccount() async throws {
        guard let session = session else { throw AuthError.invalidCredentials }
        isWorking = true
        defer { isWorking = false }
        let token = try await validAccessToken()      // refresh first if near expiry
        try await api.deleteAccount(accessToken: token)
        AccountDataEraser.erase(userId: session.user.id)
        clearLocalSession()
    }

    // MARK: - Token access (used by the sync engine, Stage 2b)

    /// A currently-valid access token, refreshing first if it's near expiry. If
    /// the refresh token is itself invalid (expired/revoked), the user is signed
    /// out and the error is rethrown so callers can route to the sign-in screen.
    func validAccessToken() async throws -> String {
        guard var session = session else { throw AuthError.invalidCredentials }
        guard session.accessTokenExpiring() else { return session.accessToken }
        do {
            session = try await api.refresh(refreshToken: session.refreshToken)
            self.session = session
            store.save(session)
            return session.accessToken
        } catch AuthError.invalidCredentials {
            clearLocalSession()
            throw AuthError.invalidCredentials
        }
    }
}
