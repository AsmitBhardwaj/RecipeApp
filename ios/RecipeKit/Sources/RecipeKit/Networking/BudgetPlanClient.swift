//
//  BudgetPlanClient.swift
//  RecipeKit
//
//  Networking for Plan on a Budget: POST /v1/meal-plan/budget. Account-scoped and
//  Pro-gated server-side, so — like PantrySuggestionsClient — every request carries
//  a Bearer access token plus the X-App-Key, and additionally the `X-Pro-Entitled`
//  claim the server checks. Injected base URL / URLSession keep it unit-testable.
//

import Foundation

public struct BudgetPlanClient {
    private let baseURL: URL
    private let session: URLSession
    private let appKey: () -> String
    private let proEntitled: @MainActor () -> Bool
    private let accessTokenProvider: () async throws -> String

    public init(
        baseURL: URL = APIRecipeProvider.defaultBaseURL,
        session: URLSession = .shared,
        appKey: @escaping () -> String = { AppConfig.appKey },
        proEntitled: @escaping @MainActor () -> Bool = { ProEntitlementCache.isEntitled },
        accessTokenProvider: @escaping () async throws -> String
    ) {
        self.baseURL = baseURL
        self.session = session
        self.appKey = appKey
        self.proEntitled = proEntitled
        self.accessTokenProvider = accessTokenProvider
    }

    public func generate(
        budget: Int,
        currency: String = "USD",
        householdSize: Int,
        dietaryPreferences: [String],
        pantryItems: [String],
        country: String?,
        areaType: String?
    ) async throws -> BudgetPlanResponse {
        var request = try await makeRequest("v1/meal-plan/budget", method: "POST")
        request.httpBody = try JSONEncoder().encode(RequestBody(
            budget: Double(budget),
            currency: currency,
            householdSize: householdSize,
            dietaryPreferences: dietaryPreferences,
            pantryItems: pantryItems,
            country: country,
            areaType: areaType
        ))
        return try await send(request)
    }

    // MARK: - Plumbing (mirrors PantrySuggestionsClient)

    private func makeRequest(_ path: String, method: String) async throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let key = appKey()
        if !key.isEmpty { request.setValue(key, forHTTPHeaderField: "X-App-Key") }
        if await proEntitled() { request.setValue("1", forHTTPHeaderField: "X-Pro-Entitled") }
        let token = try await accessTokenProvider()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send(_ request: URLRequest) async throws -> BudgetPlanResponse {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            switch urlError.code {
            case .notConnectedToInternet, .dataNotAllowed: throw BudgetPlanError.offline
            case .timedOut: throw BudgetPlanError.timedOut
            default: throw BudgetPlanError.network(urlError.localizedDescription)
            }
        }
        guard let http = response as? HTTPURLResponse else {
            throw BudgetPlanError.invalidResponse("non-HTTP response")
        }
        // Map the server's coded errors to typed cases the UI acts on.
        if http.statusCode == 403, decodeErrorCode(data) == "pro_required" {
            throw BudgetPlanError.proRequired
        }
        if http.statusCode == 400, decodeErrorCode(data) == "budget_below_minimum" {
            throw BudgetPlanError.belowMinimum(minBudget: decodeMinBudget(data) ?? 0)
        }
        if http.statusCode == 400, decodeErrorCode(data) == "budget_above_maximum" {
            throw BudgetPlanError.aboveMaximum(maxBudget: decodeMaxBudget(data) ?? 0)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw BudgetPlanError.http(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(BudgetPlanResponse.self, from: data)
        } catch {
            throw BudgetPlanError.invalidResponse("could not decode response: \(error)")
        }
    }

    // MARK: - Error envelope decoding ({ "detail": { "error_code", "min_budget" } })

    private func decodeErrorCode(_ data: Data) -> String? {
        (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.detail.errorCode
    }

    private func decodeMinBudget(_ data: Data) -> Int? {
        (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.detail.minBudget
    }

    private func decodeMaxBudget(_ data: Data) -> Int? {
        (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.detail.maxBudget
    }
}

// MARK: - Request / error bodies

private struct RequestBody: Encodable {
    let budget: Double
    let currency: String
    let householdSize: Int
    let dietaryPreferences: [String]
    let pantryItems: [String]
    let country: String?
    let areaType: String?

    enum CodingKeys: String, CodingKey {
        case budget, currency, country
        case householdSize = "household_size"
        case dietaryPreferences = "dietary_preferences"
        case pantryItems = "pantry_items"
        case areaType = "area_type"
    }
}

private struct ErrorEnvelope: Decodable {
    let detail: Detail
    struct Detail: Decodable {
        let errorCode: String?
        let minBudget: Int?
        let maxBudget: Int?
        enum CodingKeys: String, CodingKey {
            case errorCode = "error_code"
            case minBudget = "min_budget"
            case maxBudget = "max_budget"
        }
    }
}
