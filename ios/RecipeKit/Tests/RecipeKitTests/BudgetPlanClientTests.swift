//
//  BudgetPlanClientTests.swift
//  RecipeKitTests
//
//  Error mapping, request shape and the swap 409 retry for BudgetPlanClient,
//  via the shared StubURLProtocol.
//

import XCTest
@testable import RecipeKit

final class BudgetPlanClientTests: XCTestCase {

    private func makeClient() -> BudgetPlanClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return BudgetPlanClient(
            baseURL: URL(string: "https://example.test")!,
            session: URLSession(configuration: config),
            appKey: { "k" },
            accessTokenProvider: { "tok" }
        )
    }

    private func respond(_ request: URLRequest, _ status: Int, _ body: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
    }

    private func bodyJSON(_ request: URLRequest) -> [String: Any] {
        var data = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            stream.close()
        } else if let b = request.httpBody { data = b }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func generate(_ client: BudgetPlanClient, options: BudgetPlanOptions = .none) async throws -> BudgetPlanResponse {
        try await client.generate(
            budget: 75, householdSize: 2, dietaryPreferences: [], pantryItems: [],
            country: "US", areaType: nil, options: options
        )
    }

    private let mealJSON = """
    {"recipe":{"recipe_id":"r2","canonical_video_id":"budget:r2","title":"Lentil Soup",
     "servings":{"amount":2,"unit":null},"prep_time_minutes":null,"cook_time_minutes":null,
     "total_time_minutes":null,"ingredients":[],"instructions":[],"confidence":null,
     "source_type":"generated","image_url":null,"image_source":"none","transcript":null},
     "estimated_cost":{"amount":7,"currency":"USD","basis":"x"},"equipment_used":["stovetop"]}
    """

    private var swapOK: String {
        """
        {"plan_id":"p1","meal_index":1,"meal":\(mealJSON),"plan_total":40,"currency":"USD","budget":75,
         "swaps_used":1,"swaps_remaining":2}
        """
    }

    // MARK: Request shape

    func testUnconfiguredRequestStaysV10Shaped() async {
        var sent: [String: Any] = [:]
        StubURLProtocol.handler = { request in
            sent = self.bodyJSON(request)
            return self.respond(request, 500, "{}")
        }
        _ = try? await generate(makeClient())
        XCTAssertNil(sent["store_tier"])
        XCTAssertNil(sent["appliances"])
        XCTAssertNil(sent["food_moods"])
        XCTAssertNotNil(sent["household_size"])
    }

    func testConfiguredOptionsAreSent() async {
        var sent: [String: Any] = [:]
        StubURLProtocol.handler = { request in
            sent = self.bodyJSON(request)
            return self.respond(request, 500, "{}")
        }
        _ = try? await generate(makeClient(), options: .init(storeTier: "budget", appliances: ["oven"], foodMoods: ["spicy"]))
        XCTAssertEqual(sent["store_tier"] as? String, "budget")
        XCTAssertEqual(sent["appliances"] as? [String], ["oven"])
        XCTAssertEqual(sent["food_moods"] as? [String], ["spicy"])
    }

    // MARK: Generation errors

    func testFreePlanUsedMapsFromReason() async {
        StubURLProtocol.handler = { self.respond($0, 403, #"{"detail":{"error_code":"pro_required","reason":"free_plan_used"}}"#) }
        do { _ = try await generate(makeClient()); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? BudgetPlanError, .freePlanUsed) }
    }

    func testProRequiredWithoutReasonStillPaywalls() async {
        StubURLProtocol.handler = { self.respond($0, 403, #"{"detail":{"error_code":"pro_required"}}"#) }
        do { _ = try await generate(makeClient()); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? BudgetPlanError, .proRequired) }
    }

    func testGenerationApplianceUnmetIsAGenericFailureNotASwapMessage() async {
        StubURLProtocol.handler = { self.respond($0, 502, #"{"detail":{"error_code":"appliance_constraint_unmet"}}"#) }
        do { _ = try await generate(makeClient()); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? BudgetPlanError, .http(502)) }
    }

    // MARK: Swap

    func testSwapSuccessDecodes() async throws {
        StubURLProtocol.handler = { self.respond($0, 200, self.swapOK) }
        let resp = try await makeClient().swap(planID: "p1", mealIndex: 1)
        XCTAssertEqual(resp.swapsRemaining, 2)
        XCTAssertEqual(resp.planTotal, 40)
        XCTAssertEqual(resp.meal.recipe.title, "Lentil Soup")
    }

    func testSwapPostsToPlanPathWithMealIndex() async throws {
        var path = ""; var sent: [String: Any] = [:]
        StubURLProtocol.handler = { request in
            path = request.url!.path; sent = self.bodyJSON(request)
            return self.respond(request, 200, self.swapOK)
        }
        _ = try await makeClient().swap(planID: "p1", mealIndex: 3)
        XCTAssertEqual(path, "/v1/meal-plan/budget/p1/swap")
        XCTAssertEqual(sent["meal_index"] as? Int, 3)
    }

    func testSwapFreeSwapsUsed402() async {
        StubURLProtocol.handler = { self.respond($0, 402, #"{"detail":{"error_code":"free_swaps_used"}}"#) }
        do { _ = try await makeClient().swap(planID: "p1", mealIndex: 0); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? BudgetPlanError, .freeSwapsUsed) }
    }

    func testSwapConstraintUnmetBothCodes() async {
        for code in ["swap_constraint_unmet", "appliance_constraint_unmet"] {
            StubURLProtocol.handler = { self.respond($0, 502, #"{"detail":{"error_code":"\#(code)"}}"#) }
            do { _ = try await makeClient().swap(planID: "p1", mealIndex: 0); XCTFail("expected throw") }
            catch { XCTAssertEqual(error as? BudgetPlanError, .constraintUnmet, code) }
        }
    }

    func testSwapRetriesOnceOn409ThenSucceeds() async throws {
        var calls = 0
        StubURLProtocol.handler = { request in
            calls += 1
            return calls == 1
                ? self.respond(request, 409, #"{"detail":{"error_code":"plan_changed"}}"#)
                : self.respond(request, 200, self.swapOK)
        }
        let resp = try await makeClient().swap(planID: "p1", mealIndex: 1)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(resp.mealIndex, 1)
    }

    func testSwapGivesUpAfterSecond409() async {
        var calls = 0
        StubURLProtocol.handler = { request in
            calls += 1
            return self.respond(request, 409, #"{"detail":{"error_code":"plan_changed"}}"#)
        }
        do { _ = try await makeClient().swap(planID: "p1", mealIndex: 1); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? BudgetPlanError, .planChanged) }
        XCTAssertEqual(calls, 2, "exactly one retry")
    }
}
