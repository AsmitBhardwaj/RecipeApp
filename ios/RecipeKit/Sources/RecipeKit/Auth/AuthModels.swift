//
//  AuthModels.swift
//  RecipeKit
//
//  The client-side shapes for real accounts (Stage 3). `AuthUser` is the signed-in
//  identity; `AuthSession` is what we persist in the shared Keychain — the access
//  token, the refresh token, and when the access token expires so we can refresh
//  it silently before it lapses.
//

import Foundation

/// The authenticated account, as the app knows it.
public struct AuthUser: Codable, Equatable, Sendable {
    public let id: String
    public let email: String?
    public let emailVerified: Bool
    public let fullName: String?

    public init(id: String, email: String?, emailVerified: Bool, fullName: String?) {
        self.id = id
        self.email = email
        self.emailVerified = emailVerified
        self.fullName = fullName
    }
}

/// The persisted session. `accessExpiresAt` is computed from the server's
/// `expires_in` at the moment of receipt.
public struct AuthSession: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var accessExpiresAt: Date
    public var user: AuthUser
    /// Set only for a session created via Google sign-in — Google's OAuth
    /// `access_token`, kept around solely so account deletion can revoke this
    /// app's Google grant. Its presence is also how the client tells a
    /// Google-linked account apart from Apple/email (no separate provider
    /// field exists on `AuthUser`). Never sent to our backend; decodes to nil
    /// for sessions persisted before this field existed.
    public var googleAccessToken: String?

    public init(
        accessToken: String,
        refreshToken: String,
        accessExpiresAt: Date,
        user: AuthUser,
        googleAccessToken: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accessExpiresAt = accessExpiresAt
        self.user = user
        self.googleAccessToken = googleAccessToken
    }

    /// True when the access token is within `leeway` seconds of expiring (or has),
    /// i.e. it should be refreshed before the next authenticated call.
    public func accessTokenExpiring(leeway: TimeInterval = 60, now: Date = Date()) -> Bool {
        now.addingTimeInterval(leeway) >= accessExpiresAt
    }
}

// MARK: - Wire decoding (backend /auth responses)

/// Matches the backend `TokenResponse` (snake_case). Converted to `AuthSession`
/// by stamping the expiry from `expiresIn` at receipt time.
struct TokenResponseDTO: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let user: UserDTO

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case user
    }

    func session(receivedAt: Date = Date()) -> AuthSession {
        AuthSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            accessExpiresAt: receivedAt.addingTimeInterval(TimeInterval(expiresIn)),
            user: user.model
        )
    }
}

struct UserDTO: Decodable {
    let id: String
    let email: String?
    let emailVerified: Bool
    let fullName: String?

    enum CodingKeys: String, CodingKey {
        case id, email
        case emailVerified = "email_verified"
        case fullName = "full_name"
    }

    var model: AuthUser {
        AuthUser(id: id, email: email, emailVerified: emailVerified, fullName: fullName)
    }
}
