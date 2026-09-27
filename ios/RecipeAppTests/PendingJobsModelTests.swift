//
//  PendingJobsModelTests.swift
//  RecipeAppTests
//
//  Regression coverage for the site_blocked "stuck extracting indicator" bug:
//  a failed job must clear its processing card the instant the backend marks
//  it `.failed`, for every error code, independent of the one-time failure
//  alert ever being shown or dismissed. And the alert itself must only offer
//  "Paste Recipe Text" for `RecipeProviderError.pasteEligibleCodes`.
//
//  `PendingJobsModel.handleFailed` is private, so these drive it the same way
//  production code does — through `submit(url:)` against a `FakeRecipeProvider`
//  whose `fetchJob` resolves failed on the very first poll.
//

import XCTest
@testable import RecipeApp
import RecipeKit

@MainActor
final class PendingJobsModelTests: XCTestCase {

    /// Fresh, isolated `PendingJobStore` per test so parallel test runs (and
    /// any App Group fallback to `.standard`) never share state.
    private func makeModel(failureCode: String?, message: String = "failed") -> PendingJobsModel {
        let provider = FakeRecipeProvider()
        provider.failureCode = failureCode
        provider.failureMessage = message
        let defaults = UserDefaults(suiteName: "pendingjobsmodeltests-\(UUID().uuidString)")!
        return PendingJobsModel(
            provider: provider,
            userScope: "test-\(UUID().uuidString)",
            store: PendingJobStore(defaults: defaults)
        )
    }

    /// Spins (briefly, on the main actor) until `condition` is true or `timeout`
    /// elapses — used to await the background poll `Task` that `submit(url:)`
    /// starts without waiting on it.
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: 1 — failed job clears pending state immediately

    func testFailedJobClearsPendingImmediately() async throws {
        let model = makeModel(failureCode: "site_blocked")

        try await model.submit(url: "https://www.allrecipes.com/recipe/1")
        XCTAssertEqual(model.pending.count, 1, "submit() shows the processing card right away")

        await waitUntil { model.failureAlert != nil }

        // The processing card is already gone by the time the alert appears —
        // clearing it does not wait on the alert being shown or dismissed.
        XCTAssertTrue(model.pending.isEmpty, "the processing card must clear the moment the job fails")
        XCTAssertEqual(model.failed.count, 1)

        // Dismissing afterward changes nothing about `pending` — it was
        // already clear.
        model.clearFailureAlert()
        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertNil(model.failureAlert)
    }

    /// Same guarantee for a non-paste-eligible code, and for a job the app
    /// never surfaces an alert for a second time — the pending-clear must not
    /// be contingent on the alert path at all.
    func testFailedJobClearsPendingImmediatelyForNonEligibleCode() async throws {
        let model = makeModel(failureCode: "no_recipe_found")

        try await model.submit(url: "https://example.com/recipe")
        XCTAssertEqual(model.pending.count, 1)

        await waitUntil { model.pending.isEmpty }
        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertEqual(model.failed.count, 1)
    }

    // MARK: 2 — paste-eligible failure exposes the paste action

    func testPasteEligibleFailureExposesPasteAction() async throws {
        let model = makeModel(failureCode: "site_blocked")

        try await model.submit(url: "https://www.allrecipes.com/recipe/1")
        await waitUntil { model.failureAlert != nil }

        XCTAssertEqual(model.failureAlert?.canPasteText, true)
        XCTAssertEqual(model.failed.first?.canPasteText, true)
    }

    // MARK: 3 — non-eligible failure does not expose the paste action

    func testNonEligibleFailureHidesPasteAction() async throws {
        let model = makeModel(failureCode: "no_recipe_found")

        try await model.submit(url: "https://example.com/recipe")
        await waitUntil { model.failureAlert != nil }

        XCTAssertEqual(model.failureAlert?.canPasteText, false)
        XCTAssertEqual(model.failed.first?.canPasteText, false)
    }

    func testNilErrorCodeHidesPasteAction() async throws {
        let model = makeModel(failureCode: nil)

        try await model.submit(url: "https://example.com/recipe")
        await waitUntil { model.failureAlert != nil }

        XCTAssertEqual(model.failureAlert?.canPasteText, false)
    }
}
