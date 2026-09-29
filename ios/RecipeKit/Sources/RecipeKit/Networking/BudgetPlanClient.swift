//
//  BudgetPlanClient.swift
//  RecipeKit
//
//  Networking for Plan on a Budget: POST /v1/meal-plan/budget. Account-scoped and
//  Pro-gated server-side, so — like PantrySuggestionsClient — every request carries
//  a Bearer access token plus the X-App-Key. Pro is verified from the account's
//  stored entitlement server-side (no client Pro header). Injected base URL /
//  URLSession keep it unit-testable.
//

import Foundation

public struct BudgetPlanClient {
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

    public func generate(
        budget: Int,
        currency: String = "USD",
        householdSize: Int,
        dietaryPreferences: [String],
        pantryItems: [String],
        country: String?,
        areaType: String?,
        options: BudgetPlanOptions = .none
    ) async throws -> BudgetPlanResponse {
        var request = try await makeRequest("v1/meal-plan/budget", method: "POST")
        request.httpBody = try JSONEncoder().encode(RequestBody(
            budget: Double(budget),
            currency: currency,
            householdSize: householdSize,
            dietaryPreferences: dietaryPreferences,
            pantryItems: pantryItems,
            country: country,
            areaType: areaType,
            storeTier: options.storeTier,
            appliances: options.appliances,
            foodMoods: options.foodMoods
        ))
        return try await send(request, as: BudgetPlanResponse.self)
    }

    /// Replace one dinner in a stored plan. 409 `plan_changed` (a concurrent swap)
    /// is retried once here; a second 409 surfaces as `.planChanged`.
    public func swap(planID: String, mealIndex: Int) async throws -> BudgetSwapResponse {
        do {
            return try await swapOnce(planID: planID, mealIndex: mealIndex)
        } catch BudgetPlanError.planChanged {
            return try await swapOnce(planID: planID, mealIndex: mealIndex)
        }
    }

    private func swapOnce(planID: String, mealIndex: Int) async throws -> BudgetSwapResponse {
        var request = try await makeRequest("v1/meal-plan/budget/\(planID)/swap", method: "POST")
        request.httpBody = try JSONEncoder().encode(["meal_index": mealIndex])
        return try await send(request, as: BudgetSwapResponse.self)
    }

    // MARK: - Plumbing (mirrors PantrySuggestionsClient)

    private func makeRequest(_ path: String, method: String) async throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let key = appKey()
        if !key.isEmpty { request.setValue(key, forHTTPHeaderField: "X-App-Key") }
        let token = try await accessTokenProvider()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
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
        // 403 pro_required always means paywall; `reason: free_plan_used` just says why.
        if http.statusCode == 403, decodeErrorCode(data) == "pro_required" {
            throw decodeReason(data) == "free_plan_used" ? BudgetPlanError.freePlanUsed : BudgetPlanError.proRequired
        }
        if http.statusCode == 402, decodeErrorCode(data) == "free_swaps_used" {
            throw BudgetPlanError.freeSwapsUsed
        }
        if http.statusCode == 409, decodeErrorCode(data) == "plan_changed" {
            throw BudgetPlanError.planChanged
        }
        // Only the swap path treats these as "try again"; on generation they stay
        // a generic failure (see `.http`).
        if http.statusCode == 502, request.url?.path.hasSuffix("/swap") == true,
           ["swap_constraint_unmet", "appliance_constraint_unmet"].contains(decodeErrorCode(data) ?? "") {
            throw BudgetPlanError.constraintUnmet
        }
        if http.statusCode == 400, decodeErrorCode(data) == "budget_below_minimum" {
            throw BudgetPlanError.belowMinimum(minBudget: decodeMinBudget(data) ?? 0)
        }
        if http.statusCode == 400, decodeErrorCode(data) == "budget_above_maximum" {
            throw BudgetPlanError.aboveMaximum(maxBudget: decodeMaxBudget(data) ?? 0)
        }
        if http.statusCode == 429, decodeErrorCode(data) == "spend_cap_reached" {
            throw BudgetPlanError.spendCapReached
        }
        guard (200..<300).contains(http.statusCode) else {
            throw BudgetPlanError.http(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw BudgetPlanError.invalidResponse("could not decode response: \(error)")
        }
    }

    // MARK: - Error envelope decoding ({ "detail": { "error_code", "min_budget" } })

    private func decodeErrorCode(_ data: Data) -> String? {
        (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.detail.errorCode
    }

    private func decodeReason(_ data: Data) -> String? {
        (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.detail.reason
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
    // v1.1 fields: nil is omitted by the synthesized encoder, keeping an
    // unconfigured request v1.0-shaped.
    let storeTier: String?
    let appliances: [String]?
    let foodMoods: [String]?

    enum CodingKeys: String, CodingKey {
        case budget, currency, country, appliances
        case storeTier = "store_tier"
        case foodMoods = "food_moods"
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
        let reason: String?
        let minBudget: Int?
        let maxBudget: Int?
        enum CodingKeys: String, CodingKey {
            case errorCode = "error_code"
            case reason
            case minBudget = "min_budget"
            case maxBudget = "max_budget"
        }
    }
}
