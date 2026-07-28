//
//  APIRecipeProviderTests.swift
//  RecipeKitTests
//
//  Deterministic tests of submit→poll and error mapping using a URLProtocol
//  stub — no real network. Verifies the provider decodes the real `{job,recipe}`
//  envelope, polls until terminal, and maps failures to typed states.
//

import XCTest
@testable import RecipeKit

// MARK: - URLProtocol stub

final class StubURLProtocol: URLProtocol {
    /// Returns (response, body) for a request, or throws to simulate transport failure.
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = StubURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown)); return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

final class APIRecipeProviderTests: XCTestCase {

    private func makeProvider() -> APIRecipeProvider {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return APIRecipeProvider(
            baseURL: URL(string: "https://example.test")!,
            session: URLSession(configuration: config),
            userID: { "test-user" },
            pollInterval: .milliseconds(5),
            maxWait: .seconds(2)
        )
    }

    private func ok(_ json: String, for request: URLRequest) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
         Data(json.utf8))
    }

    private let queuedJSON = """
    {"job":{"job_id":"J1","user_id":"u","url":"x","canonical_video_id":null,"platform":null,
    "status":"queued","extraction_method":"caption_only","created_at":"t","recipe_id":null,
    "error_code":null,"error":null},"recipe":null}
    """

    private let completeJSON = """
    {"job":{"job_id":"J1","user_id":"u","url":"x","canonical_video_id":"ig:1","platform":"instagram",
    "status":"complete","extraction_method":"caption_only","created_at":"t","recipe_id":"R1",
    "error_code":null,"error":null},
    "recipe":{"recipe_id":"R1","canonical_video_id":"ig:1","title":"Gratin Dauphinois",
    "servings":{"amount":null,"unit":null},"prep_time_minutes":null,"cook_time_minutes":90.0,
    "total_time_minutes":null,"ingredients":[{"quantity":1.5,"unit":"kg","name":"potatoes","notes":null}],
    "instructions":[{"step_number":1,"text":"Slice."}],
    "confidence":{"overall":0.8,"ingredients_complete":true,"instructions_complete":true,"missing_fields":[]},
    "source_type":"caption","image_url":null,"image_source":"none","transcript":null,"nutrition":null}}
    """

    private let failedJSON = """
    {"job":{"job_id":"J1","user_id":"u","url":"x","canonical_video_id":"ig:1","platform":"instagram",
    "status":"failed","extraction_method":"caption_only","created_at":"t","recipe_id":null,
    "error_code":"caption_not_found","error":"Could not extract a caption for this reel."},"recipe":null}
    """

    func testSubmitThenPollReturnsDecodedRecipe() async throws {
        var calls = 0
        StubURLProtocol.handler = { request in
            calls += 1
            // 1st call = POST (queued). 2nd call = still queued. 3rd+ = complete.
            let json = calls >= 3 ? self.completeJSON : self.queuedJSON
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(json.utf8))
        }
        let recipe = try await makeProvider().submitRecipe(url: "https://www.instagram.com/reel/DZ5XB_colZ3/")
        XCTAssertEqual(recipe.title, "Gratin Dauphinois")
        XCTAssertEqual(recipe.cookTimeMinutes, 90)
        XCTAssertEqual(recipe.ingredients.first?.name, "potatoes")
        XCTAssertGreaterThanOrEqual(calls, 3, "should have polled after the queued POST")
    }

    func testFailedJobMapsToJobFailedError() async {
        StubURLProtocol.handler = { request in
            let isPost = request.httpMethod == "POST"
            let json = isPost ? self.queuedJSON : self.failedJSON
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(json.utf8))
        }
        do {
            _ = try await makeProvider().submitRecipe(url: "https://www.instagram.com/reel/bad/")
            XCTFail("expected failure")
        } catch let error as RecipeProviderError {
            XCTAssertEqual(error, .jobFailed(code: "caption_not_found",
                                             message: "Could not extract a caption for this reel."))
        } catch {
            XCTFail("expected RecipeProviderError, got \(error)")
        }
    }

    func testOfflineMapsToOfflineError() async {
        StubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await makeProvider().submitJob(url: "https://www.instagram.com/reel/x/")
            XCTFail("expected failure")
        } catch let error as RecipeProviderError {
            XCTAssertEqual(error, .offline)
        } catch {
            XCTFail("expected RecipeProviderError, got \(error)")
        }
    }

    func testHTTPErrorMapsToHTTPStatus() async {
        StubURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!,
             Data("{\"detail\":\"rate limited\"}".utf8))
        }
        do {
            _ = try await makeProvider().submitJob(url: "https://www.instagram.com/reel/x/")
            XCTFail("expected failure")
        } catch let error as RecipeProviderError {
            XCTAssertEqual(error, .httpStatus(429))
        } catch {
            XCTFail("expected RecipeProviderError, got \(error)")
        }
    }

    func testEmptyURLIsInvalidURL() async {
        do {
            _ = try await makeProvider().submitJob(url: "   ")
            XCTFail("expected failure")
        } catch let error as RecipeProviderError {
            XCTAssertEqual(error, .invalidURL)
        } catch {
            XCTFail("expected RecipeProviderError, got \(error)")
        }
    }

    func testFetchRecipesReturnsEmptyWhenNoListEndpoint() async throws {
        let recipes = try await makeProvider().fetchRecipes()
        XCTAssertTrue(recipes.isEmpty)
    }
}
