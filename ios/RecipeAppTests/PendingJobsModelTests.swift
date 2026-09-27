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
        return makeModel(provider: provider)
    }

    private func makeModel(
        provider: FakeRecipeProvider,
        pollInterval: Duration = .seconds(1.5),
        maxWait: Duration = .seconds(120)
    ) -> PendingJobsModel {
        let defaults = UserDefaults(suiteName: "pendingjobsmodeltests-\(UUID().uuidString)")!
        return PendingJobsModel(
            provider: provider,
            userScope: "test-\(UUID().uuidString)",
            store: PendingJobStore(defaults: defaults),
            pollInterval: pollInterval,
            maxWait: maxWait
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

    // MARK: 4 — removePending (the stuck-forever escape hatch)

    /// A job stuck showing "Extracting recipe…" (e.g. one whose poll ran past
    /// its budget with no automatic re-arm) must be removable with no server
    /// call — purely local, immediate.
    func testRemovePendingClearsImmediatelyWithNoServerCall() async throws {
        let provider = FakeRecipeProvider()
        let defaults = UserDefaults(suiteName: "pendingjobsmodeltests-\(UUID().uuidString)")!
        let store = PendingJobStore(defaults: defaults)
        let model = PendingJobsModel(provider: provider, userScope: "test-\(UUID().uuidString)", store: store)

        try await model.submit(url: "https://www.gimmesomeoven.com/authentic-gazpacho-recipe/")
        XCTAssertEqual(model.pending.count, 1)
        let jobId = model.pending[0].jobId

        model.removePending(jobId: jobId)

        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertTrue(store.all().isEmpty, "removal must be reflected in the durable store, not just the in-memory list")
    }

    /// If a poll is still in flight when the user removes the card, its
    /// eventual terminal result must not resurrect a failed card or alert for
    /// a job the user already dismissed.
    func testRemovePendingDiscardsInFlightPollResult() async throws {
        let provider = FakeRecipeProvider()
        provider.failureCode = "no_recipe_found"
        provider.fetchJobDelay = .milliseconds(150)
        let model = makeModel(provider: provider)

        try await model.submit(url: "https://www.gimmesomeoven.com/authentic-gazpacho-recipe/")
        XCTAssertEqual(model.pending.count, 1)
        model.removePending(jobId: model.pending[0].jobId)
        XCTAssertTrue(model.pending.isEmpty)

        // Let the delayed poll resolve (it would otherwise reach handleFailed).
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertTrue(model.failed.isEmpty, "a removed job's late poll result must not resurrect a failed card")
        XCTAssertNil(model.failureAlert)
    }

    // MARK: 5 — poll budget expiry always resolves the card (never leaves it pending)

    /// A job still `.processing` when the poll budget runs out (e.g. a slow
    /// fetch, or an app that was suspended through most of the budget) must
    /// still clear its card — converted to a local, paste-eligible failure —
    /// rather than being left stuck showing "Extracting recipe…" forever.
    func testBudgetExpiryWithStillProcessingJobProducesPasteEligibleFailure() async throws {
        let provider = FakeRecipeProvider()
        provider.alwaysProcessing = true
        // Zero budget: the poll loop runs zero iterations and goes straight to
        // the post-budget final check, which this provider also answers
        // `.processing` — exercising "still not terminal after the final check".
        let model = makeModel(provider: provider, maxWait: .zero)

        try await model.submit(url: "https://www.gimmesomeoven.com/authentic-gazpacho-recipe/")
        await waitUntil { model.failureAlert != nil }

        XCTAssertTrue(model.pending.isEmpty, "the card must clear even though the job never went terminal")
        XCTAssertEqual(model.failed.first?.errorCode, RecipeProviderError.clientTimeoutCode)
        XCTAssertEqual(model.failureAlert?.canPasteText, true, "the synthesized timeout must offer Paste Recipe Text")
    }

    /// If the post-budget final check finds the job already terminal, it must
    /// be handled exactly like a normal in-loop terminal result — the
    /// server's own code/message, not the synthesized client timeout.
    func testBudgetExpiryWhereFinalCheckFindsJobTerminalHandlesNormally() async throws {
        let provider = FakeRecipeProvider()
        provider.failureCode = "no_recipe_found"  // a real, non-eligible server code
        let model = makeModel(provider: provider, maxWait: .zero)

        try await model.submit(url: "https://example.com/recipe")
        await waitUntil { model.failureAlert != nil }

        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertEqual(model.failed.first?.errorCode, "no_recipe_found",
                       "a job the final check finds terminal keeps its own server code, not client_timeout")
        XCTAssertEqual(model.failureAlert?.canPasteText, false)
    }
}
