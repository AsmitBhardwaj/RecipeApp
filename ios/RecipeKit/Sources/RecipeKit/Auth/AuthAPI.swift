//
//  AuthAPI.swift
//  RecipeKit
//
//  Networking for the /auth/* endpoints. Same conventions as APIRecipeProvider:
//  the abuse-deterrence `X-App-Key` header on every call, JSON bodies, injected
//  base URL + URLSession so it's unit-testable with a URLProtocol stub. Returns
//  typed `AuthError`s the sign-in UI can act on.
//
//  These endpoints do NOT send `X-User-Id` — identity here is the verified
//  account (a provider token, credentials, or a Bearer token), not the anonymous
//  device UUID.
//

import Foundation

public struct AuthAPI {
    private let baseURL: URL
    private let session: URLSession
    private let appKey: () -> String

    public init(
        baseURL: URL = APIRecipeProvider.defaultBaseURL,
        session: URLSession = .shared,
        appKey: @escaping () -> String = { AppConfig.appKey }
    ) {
        self.baseURL = baseURL
        self.session = session
        self.appKey = appKey
    }

    // MARK: - Endpoints

    public func register(email: String, password: String, fullName: String?) async throws -> AuthSession {
        try await tokenCall("auth/register", body: [
            "email": email, "password": password, "full_name": fullName,
        ])
    }

    public func login(email: String, password: String) async throws -> AuthSession {
        try await tokenCall("auth/login", body: ["email": email, "password": password])
    }

    public func apple(identityToken: String, fullName: String?) async throws -> AuthSession {
        try await tokenCall("auth/apple", body: [
            "identity_token": identityToken, "full_name": fullName,
        ])
    }

    public func google(idToken: String, fullName: String?) async throws -> AuthSession {
        try await tokenCall("auth/google", body: ["id_token": idToken, "full_name": fullName])
    }

    public func refresh(refreshToken: String) async throws -> AuthSession {
        try await tokenCall("auth/refresh", body: ["refresh_token": refreshToken])
    }

    /// Best-effort: revoke the refresh token server-side. Ignores failures —
    /// the client is signing out regardless.
    public func logout(refreshToken: String) async {
        var request = makeRequest("auth/logout", method: "POST")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])
        _ = try? await session.data(for: request)
    }

    // MARK: - Plumbing

    private func tokenCall(_ path: String, body: [String: String?]) async throws -> AuthSession {
        var request = makeRequest(path, method: "POST")
        // Drop nil values so absent optionals aren't sent as JSON null.
        let payload = body.compactMapValues { $0 }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let dto: TokenResponseDTO = try await send(request)
        return dto.session()
    }

    private func makeRequest(_ path: String, method: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let key = appKey()
        if !key.isEmpty {
            request.setValue(key, forHTTPHeaderField: "X-App-Key")
        }
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            switch urlError.code {
            case .notConnectedToInternet, .dataNotAllowed:
                throw AuthError.offline
            case .timedOut:
                throw AuthError.timedOut
            default:
                throw AuthError.invalidResponse(urlError.localizedDescription)
            }
        }
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            switch http.statusCode {
            case 401: throw AuthError.invalidCredentials
            case 409: throw AuthError.emailInUse
            case 429: throw AuthError.rateLimited
            default: throw AuthError.server(http.statusCode)
            }
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AuthError.invalidResponse("could not decode response: \(error)")
        }
    }
}
