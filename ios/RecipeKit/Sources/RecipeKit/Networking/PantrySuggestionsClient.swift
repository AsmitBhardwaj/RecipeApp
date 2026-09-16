//
//  PantrySuggestionsClient.swift
//  RecipeKit
//
//  Networking for the pantry-suggestion API: POST /v1/pantry/suggestions.
//  This is an ACCOUNT-SCOPED endpoint (the server reads the caller's pantry and
//  scopes work to them), so — like SyncClient and unlike the unauthenticated
//  APIRecipeProvider — every request carries a Bearer access token from
//  `accessTokenProvider` (in the app, AuthModel.validAccessToken, which refreshes
//  silently) alongside the abuse-deterrence `X-App-Key`.
//
//  Injected base URL / URLSession keep this unit-testable with a URLProtocol stub,
//  matching the other clients here.
//

import Foundation

public struct PantrySuggestionsClient {
    private let baseURL: URL
    private let session: URLSession
    private let appKey: () -> String
    private let accessTokenProvider: () async throws -> String

    public init(
        baseURL: URL = APIRecipeProvider.defaultBaseURL,
        session: URLSession = .shared,
        appKey: @escaping () -> String = { AppConfig.appKey },
        accessTokenProvider: @escaping () async throws -> String
    ) {
        self.baseURL = baseURL
        self.session = session
        self.appKey = appKey
        self.accessTokenProvider = accessTokenProvider
    }

    /// POST /v1/pantry/suggestions.
    ///
    /// - Parameters:
    ///   - limit: max suggestions to return (server caps at 50).
    ///   - pantryOverride: when non-nil, the pantry to match against instead of
    ///     the user's synced pantry. The app passes the LOCAL pantry names here so
    ///     suggestions reflect exactly what's on screen without waiting for the
    ///     pantry to round-trip through sync.
    ///   - allowGeneration: whether the sparse-results generation fallback may run.
    public func suggestions(
        limit: Int = 20,
        pantryOverride: [String]? = nil,
        allowGeneration: Bool = true
    ) async throws -> PantrySuggestionsResponse {
        var request = try await makeRequest("v1/pantry/suggestions", method: "POST")
        request.httpBody = try JSONEncoder().encode(
            RequestBody(limit: limit, pantryOverride: pantryOverride, allowGeneration: allowGeneration)
        )
        return try await send(request)
    }

    // MARK: - Plumbing (mirrors SyncClient)

    private func makeRequest(_ path: String, method: String) async throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let key = appKey()
        if !key.isEmpty {
            request.setValue(key, forHTTPHeaderField: "X-App-Key")
        }
        let token = try await accessTokenProvider()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send(_ request: URLRequest) async throws -> PantrySuggestionsResponse {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            switch urlError.code {
            case .notConnectedToInternet, .dataNotAllowed: throw RecipeProviderError.offline
            case .timedOut: throw RecipeProviderError.timedOut
            default: throw RecipeProviderError.network(urlError.localizedDescription)
            }
        }
        guard let http = response as? HTTPURLResponse else {
            throw RecipeProviderError.invalidResponse("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RecipeProviderError.httpStatus(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(PantrySuggestionsResponse.self, from: data)
        } catch {
            throw RecipeProviderError.invalidResponse("could not decode response: \(error)")
        }
    }
}

// MARK: - Request body

private struct RequestBody: Encodable {
    let limit: Int
    let pantryOverride: [String]?
    let allowGeneration: Bool

    enum CodingKeys: String, CodingKey {
        case limit
        case pantryOverride = "pantry_override"
        case allowGeneration = "allow_generation"
    }
}
