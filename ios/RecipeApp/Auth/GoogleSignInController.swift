//
//  GoogleSignInController.swift
//  RecipeApp
//
//  Google sign-in WITHOUT the GoogleSignIn SDK — a standard OAuth 2.0 + PKCE
//  flow over ASWebAuthenticationSession. It returns the Google `id_token`, which
//  the backend verifies (POST /auth/google). No client secret is used (iOS is a
//  public client; PKCE is the protection).
//
//  Config comes from Secrets.xcconfig → Info.plist:
//    GOOGLE_CLIENT_ID           the iOS OAuth client id
//    GOOGLE_REVERSED_CLIENT_ID  reversed client id — the redirect URL scheme
//  When unset, `AppConfig.isGoogleConfigured` is false and callers should not
//  offer Google sign-in.
//

import AuthenticationServices
import CryptoKit
import Foundation
import RecipeKit

@MainActor
final class GoogleSignInController: NSObject, ASWebAuthenticationPresentationContextProviding {

    private var session: ASWebAuthenticationSession?

    /// Runs the interactive flow and returns a Google `id_token`. Throws
    /// `AuthError.notConfigured` / `.cancelled` / `.invalidResponse`.
    func idToken() async throws -> String {
        guard AppConfig.isGoogleConfigured else { throw AuthError.notConfigured("Google") }

        let clientID = AppConfig.googleClientID
        let redirectScheme = AppConfig.googleReversedClientID
        let redirectURI = "\(redirectScheme):/oauth2redirect"

        let verifier = Self.codeVerifier()
        let challenge = Self.codeChallenge(for: verifier)
        let state = Self.randomURLSafe(32)
        let nonce = Self.randomURLSafe(32)

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "openid email profile"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "nonce", value: nonce),
        ]

        let callbackURL = try await authorize(url: comps.url!, callbackScheme: redirectScheme)

        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state else {
            throw AuthError.invalidResponse("Google state mismatch")
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw AuthError.invalidResponse("Google returned no authorization code")
        }

        return try await exchange(code: code, verifier: verifier, clientID: clientID, redirectURI: redirectURI)
    }

    // MARK: - Steps

    private func authorize(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callback, error in
                if let error {
                    let code = (error as? ASWebAuthenticationSessionError)?.code
                    continuation.resume(throwing: code == .canceledLogin ? AuthError.cancelled : AuthError.invalidResponse(error.localizedDescription))
                    return
                }
                guard let callback else {
                    continuation.resume(throwing: AuthError.invalidResponse("Google returned no callback"))
                    return
                }
                continuation.resume(returning: callback)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            session.start()
        }
    }

    private func exchange(code: String, verifier: String, clientID: String, redirectURI: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "code", value: code),
            .init(name: "code_verifier", value: verifier),
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "redirect_uri", value: redirectURI),
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AuthError.invalidResponse("Google token exchange failed")
        }
        struct TokenResponse: Decodable { let id_token: String }
        guard let token = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw AuthError.invalidResponse("Google token response had no id_token")
        }
        return token.id_token
    }

    // MARK: - PKCE helpers

    private static func codeVerifier() -> String { randomURLSafe(64) }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    private static func randomURLSafe(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return data.base64URLEncodedString()
    }

    // MARK: - Presentation anchor

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first?.windows.first
            return window ?? ASPresentationAnchor()
        }
    }
}

private extension Data {
    /// Base64URL without padding — the encoding PKCE + JWTs use.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
