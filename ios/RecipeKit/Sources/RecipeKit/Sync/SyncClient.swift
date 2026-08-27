//
//  SyncClient.swift
//  RecipeKit
//
//  Networking for the sync API: POST /v1/sync/push, GET /v1/sync/pull, and
//  POST /v1/recipes/batch. Every call carries the abuse-deterrence `X-App-Key`
//  and a Bearer access token obtained from `accessTokenProvider` — in the app
//  that's `AuthModel.validAccessToken()`, which refreshes silently. A 401 maps
//  to `SyncError.unauthorized` so the engine can surface a re-auth.
//
//  Injected base URL / URLSession keep this unit-testable with a URLProtocol
//  stub, like AuthAPI and APIRecipeProvider.
//

import Foundation

public struct SyncClient {
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

    // MARK: - Endpoints

    public func push(_ changes: [SyncChange]) async throws -> SyncPushResult {
        var request = try await makeRequest("v1/sync/push", method: "POST")
        request.httpBody = try JSONEncoder().encode(PushBody(changes: changes))
        let dto: PushResponseDTO = try await send(request)
        return SyncPushResult(applied: dto.applied, conflicts: dto.conflicts, cursor: dto.cursor)
    }

    public func pull(cursor: Int64, limit: Int = 500) async throws -> SyncPullResult {
        var comps = URLComponents(url: baseURL.appendingPathComponent("v1/sync/pull"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "cursor", value: String(cursor)), .init(name: "limit", value: String(limit))]
        var request = try await makeRequest(url: comps.url!, method: "GET")
        request.httpBody = nil
        let dto: PullResponseDTO = try await send(request)
        return SyncPullResult(changes: dto.changes, cursor: dto.cursor, hasMore: dto.hasMore)
    }

    public func recipes(ids: [String]) async throws -> [Recipe] {
        var request = try await makeRequest("v1/recipes/batch", method: "POST")
        request.httpBody = try JSONEncoder().encode(BatchBody(ids: ids))
        let dto: BatchResponseDTO = try await send(request)
        return dto.recipes
    }

    // MARK: - Plumbing

    private func makeRequest(_ path: String, method: String) async throws -> URLRequest {
        try await makeRequest(url: baseURL.appendingPathComponent(path), method: method)
    }

    private func makeRequest(url: URL, method: String) async throws -> URLRequest {
        var request = URLRequest(url: url)
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

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            switch urlError.code {
            case .notConnectedToInternet, .dataNotAllowed: throw SyncError.offline
            case .timedOut: throw SyncError.timedOut
            default: throw SyncError.invalidResponse(urlError.localizedDescription)
            }
        }
        guard let http = response as? HTTPURLResponse else {
            throw SyncError.invalidResponse("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw SyncError.unauthorized }
            throw SyncError.server(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SyncError.invalidResponse("could not decode response: \(error)")
        }
    }
}

// MARK: - Wire bodies / responses

private struct PushBody: Encodable {
    let changes: [SyncChange]
}

private struct BatchBody: Encodable {
    let ids: [String]
}

private struct PushResponseDTO: Decodable {
    let applied: [String]
    let conflicts: [SyncChange]
    let cursor: Int64
}

private struct PullResponseDTO: Decodable {
    let changes: [SyncChange]
    let cursor: Int64
    let hasMore: Bool
    enum CodingKeys: String, CodingKey {
        case changes, cursor
        case hasMore = "has_more"
    }
}

private struct BatchResponseDTO: Decodable {
    let recipes: [Recipe]
}
