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
        maxWait: Duration = .seconds(120),
        perPollTimeout: Duration = .seconds(20),
        activePollStaleAfter: TimeInterval = 300
    ) -> PendingJobsModel {
        let defaults = UserDefaults(suiteName: "pendingjobsmodeltests-\(UUID().uuidString)")!
        return PendingJobsModel(
            provider: provider,
            userScope: "test-\(UUID().uuidString)",
            store: PendingJobStore(defaults: defaults),
            pollInterval: pollInterval,
            maxWait: maxWait,
            perPollTimeout: perPollTimeout,
            activePollStaleAfter: activePollStaleAfter
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

    // MARK: 4b — removePendingMatching (clears every pending card for a URL,
    // not just the one job id a failure alert happens to carry)

    /// Two pending entries for the same URL (e.g. a stale one left over from an
    /// older build plus a fresh resubmission) must both clear when the user
    /// dismisses the failure alert for that URL — not just the one job id the
    /// alert was keyed to.
    func testRemovePendingMatchingRemovesAllEntriesForTheSameURL() async throws {
        let defaults = UserDefaults(suiteName: "pendingjobsmodeltests-\(UUID().uuidString)")!
        let store = PendingJobStore(defaults: defaults)
        let url = "https://www.gimmesomeoven.com/authentic-gazpacho-recipe/"
        store.upsert(PendingJob(jobId: "job-1", url: url))
        store.upsert(PendingJob(jobId: "job-2", url: url))
        let model = PendingJobsModel(provider: FakeRecipeProvider(), userScope: "test-\(UUID().uuidString)", store: store)
        XCTAssertEqual(model.pending.count, 2)

        model.removePendingMatching(url: url)

        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertTrue(store.all().isEmpty, "removal must be reflected in the durable store, not just the in-memory list")
    }

    /// A pending entry for a different URL must survive — only the failed URL's
    /// entries are cleared.
    func testRemovePendingMatchingLeavesOtherURLsAlone() async throws {
        let defaults = UserDefaults(suiteName: "pendingjobsmodeltests-\(UUID().uuidString)")!
        let store = PendingJobStore(defaults: defaults)
        let target = "https://www.gimmesomeoven.com/authentic-gazpacho-recipe/"
        let other = "https://www.allrecipes.com/recipe/1"
        store.upsert(PendingJob(jobId: "job-1", url: target))
        store.upsert(PendingJob(jobId: "job-2", url: other))
        let model = PendingJobsModel(provider: FakeRecipeProvider(), userScope: "test-\(UUID().uuidString)", store: store)

        model.removePendingMatching(url: target)

        XCTAssertEqual(model.pending.map(\.jobId), ["job-2"])
        XCTAssertEqual(store.all().map(\.jobId), ["job-2"])
    }

    /// `removePendingMatching` must match on the same canonical URL, not exact
    /// string equality — a paste with a trailing newline (unTrimmed by
    /// `AddRecipeView` at submit time) previously produced a pending entry
    /// that looked identical on screen but wouldn't match the failed job's
    /// exact `url` string.
    func testRemovePendingMatchingMatchesCanonicalURLNotExactString() async throws {
        let defaults = UserDefaults(suiteName: "pendingjobsmodeltests-\(UUID().uuidString)")!
        let store = PendingJobStore(defaults: defaults)
        store.upsert(PendingJob(jobId: "job-1", url: "https://www.gimmesomeoven.com/authentic-gazpacho-recipe/"))
        store.upsert(PendingJob(jobId: "job-2", url: "  https://www.gimmesomeoven.com/authentic-gazpacho-recipe/\n"))
        let model = PendingJobsModel(provider: FakeRecipeProvider(), userScope: "test-\(UUID().uuidString)", store: store)
        XCTAssertEqual(model.pending.count, 2)

        model.removePendingMatching(url: "https://www.gimmesomeoven.com/authentic-gazpacho-recipe/")

        XCTAssertTrue(model.pending.isEmpty, "a whitespace-only difference must not let a duplicate survive")
        XCTAssertTrue(store.all().isEmpty)
    }

    // MARK: 4c — reconcile() self-heals: dedupes duplicates and resolves
    // already-stale entries immediately, so a removal (or a job left behind
    // by an older/cut-short launch) can never come back or stick around.

    /// Two pending entries that canonicalize to the same URL must collapse to
    /// the newest one the moment `reconcile()` runs (launch or foreground) —
    /// not only when the user notices and manually removes one.
    func testReconcileDedupesEntriesForTheSameCanonicalURL() async throws {
        let defaults = UserDefaults(suiteName: "pendingjobsmodeltests-\(UUID().uuidString)")!
        let store = PendingJobStore(defaults: defaults)
        let older = PendingJob(jobId: "job-old", url: "https://www.gimmesomeoven.com/authentic-gazpacho-recipe/",
                                submittedAt: Date().addingTimeInterval(-10))
        let newer = PendingJob(jobId: "job-new", url: "  https://www.gimmesomeoven.com/authentic-gazpacho-recipe/  ",
                                submittedAt: Date())
        store.upsert(older)
        store.upsert(newer)
        let model = PendingJobsModel(provider: FakeRecipeProvider(), userScope: "test-\(UUID().uuidString)", store: store)

        model.reconcile()

        XCTAssertEqual(model.pending.map(\.jobId), ["job-new"], "the newer entry survives, the canonical duplicate is dropped")
        XCTAssertEqual(store.all().map(\.jobId), ["job-new"])
    }

    /// A pending entry already older than `maxWait` (e.g. left over from a
    /// launch that got backgrounded/killed before its own poll could finish)
    /// must resolve via exactly one `fetchJob` call on this `reconcile()` —
    /// not a fresh `pollInterval`-spaced loop that hands it another full
    /// `maxWait` budget it may again not get to finish.
    func testReconcileResolvesAlreadyStaleJobViaSingleFinalCheck() async throws {
        let provider = FakeRecipeProvider()
        provider.failureCode = "site_blocked"
        let defaults = UserDefaults(suiteName: "pendingjobsmodeltests-\(UUID().uuidString)")!
        let store = PendingJobStore(defaults: defaults)
        store.upsert(PendingJob(
            jobId: "job-under-test",
            url: "https://www.gimmesomeoven.com/authentic-gazpacho-recipe/",
            submittedAt: Date().addingTimeInterval(-500)   // well past the 120s default maxWait
        ))
        let model = PendingJobsModel(provider: provider, userScope: "test-\(UUID().uuidString)", store: store)

        model.reconcile()
        await waitUntil { model.failureAlert != nil }

        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertEqual(model.failed.first?.errorCode, "site_blocked")
        XCTAssertEqual(provider.callCount, 1, "an already-stale job must resolve via one call, not a fresh poll loop")
    }

    /// The core regression this bug report asked for: remove a pending card,
    /// then simulate the next launch/foreground (`reconcile()`, against a
    /// *fresh* model instance sharing the same durable store) — the card must
    /// not come back.
    func testRemovedJobStaysRemovedAcrossReconcileOnAFreshModelInstance() async throws {
        let defaults = UserDefaults(suiteName: "pendingjobsmodeltests-\(UUID().uuidString)")!
        let store = PendingJobStore(defaults: defaults)
        let url = "https://www.gimmesomeoven.com/authentic-gazpacho-recipe/"
        store.upsert(PendingJob(jobId: "job-1", url: url))

        let firstLaunch = PendingJobsModel(provider: FakeRecipeProvider(), userScope: "test-\(UUID().uuidString)", store: store)
        firstLaunch.removePendingMatching(url: url)
        XCTAssertTrue(store.all().isEmpty)

        // A relaunch constructs a brand-new PendingJobsModel against the same
        // durable store — `removedJobIds`/`activePolls` reset, so only the
        // store's own contents (or lack thereof) can matter here.
        let provider = FakeRecipeProvider()
        let secondLaunch = PendingJobsModel(provider: provider, userScope: "test-\(UUID().uuidString)", store: store)
        XCTAssertTrue(secondLaunch.pending.isEmpty, "the store must not have resurrected the removed job on init")

        secondLaunch.reconcile()
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(secondLaunch.pending.isEmpty, "reconcile() on a fresh instance must not bring the removed job back")
        XCTAssertEqual(provider.callCount, 0, "there is nothing left to poll — reconcile() must not invent a job to check")
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

    // MARK: 6 — the poll loop must survive a single hung call, and must never
    // be permanently blocked by one that never recovers (the actual root
    // cause behind the gimmesomeoven.com incident: server logs showed exactly
    // one poll ever reach the backend, then silence, even while the app kept
    // making other requests — the SECOND `fetchJob` call itself never
    // returned, so `poll()`'s own budget check was never reached again).

    /// The most direct sanity check that multi-iteration polling actually
    /// works at all: first call processing, second call terminal.
    func testSecondPollIsMadeAndHandledAfterAFirstNonTerminalResponse() async throws {
        let provider = FakeRecipeProvider()
        provider.processingCallsBeforeTerminal = 1
        provider.failureCode = "site_blocked"
        let model = makeModel(provider: provider, pollInterval: .milliseconds(10), maxWait: .seconds(120))

        try await model.submit(url: "https://www.gimmesomeoven.com/authentic-gazpacho-recipe/")
        await waitUntil { model.failureAlert != nil }

        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertEqual(model.failed.first?.errorCode, "site_blocked")
    }

    /// If a single poll call hangs (never returns) but a later one recovers,
    /// the loop must not be stuck on the hung call forever — `perPollTimeout`
    /// times it out, the loop retries, and the next call is handled normally.
    /// Without the per-call timeout, this test itself would hang rather than
    /// merely fail — the strongest possible demonstration of the bug.
    func testASingleHungPollTimesOutAndTheLoopRecovers() async throws {
        let provider = FakeRecipeProvider()
        provider.processingCallsBeforeTerminal = 1  // call 1: processing
        provider.hangOnExactlyCall = 2                // call 2: hangs, then recovers
        provider.failureCode = "site_blocked"        // call 3 (after the timeout): failed
        let model = makeModel(
            provider: provider,
            pollInterval: .milliseconds(10),
            maxWait: .seconds(120),
            perPollTimeout: .milliseconds(50)
        )

        try await model.submit(url: "https://www.gimmesomeoven.com/authentic-gazpacho-recipe/")
        await waitUntil(timeout: 5) { model.failureAlert != nil }

        XCTAssertTrue(model.pending.isEmpty, "a single hung call must not leave the card stuck")
        XCTAssertEqual(model.failed.first?.errorCode, "site_blocked",
                       "recovers to the server's own terminal result once the hang is timed out")
    }

    /// If EVERY call from the second one on hangs forever (the network path
    /// never recovers), `poll()` must still resolve — via the budget's final
    /// check, itself also time-bounded — rather than hang indefinitely. This
    /// is the structural guarantee: no path through `poll()` can silently
    /// never finish.
    func testPermanentlyHungPollsStillResolveViaBudgetExpiry() async throws {
        let provider = FakeRecipeProvider()
        provider.processingCallsBeforeTerminal = 1
        provider.hangOnOrAfterCall = 2   // every call from here on hangs, permanently
        let model = makeModel(
            provider: provider,
            pollInterval: .milliseconds(10),
            maxWait: .milliseconds(100),
            perPollTimeout: .milliseconds(30)
        )

        try await model.submit(url: "https://www.gimmesomeoven.com/authentic-gazpacho-recipe/")
        await waitUntil(timeout: 5) { model.failureAlert != nil }

        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertEqual(model.failureAlert?.errorCode, RecipeProviderError.clientTimeoutCode)
        XCTAssertEqual(model.failureAlert?.canPasteText, true)
    }

    /// `reconcile()`/`startPolling` must not be permanently blocked from
    /// re-polling a job just because `activePolls` still thinks a poll for it
    /// is live — the defensive backstop for the case where something
    /// upstream of `poll()`'s own guarantees somehow still leaves an entry
    /// wedged (answers "does reconcile() skip jobs it thinks already have a
    /// live loop?" — yes, but only until `activePollStaleAfter`).
    func testStaleActivePollEntryLetsReconcileTryAgain() async throws {
        let provider = FakeRecipeProvider()
        provider.processingCallsBeforeTerminal = 999  // never terminal on its own
        provider.fetchJobDelay = .seconds(2)           // each call is slow, not hung
        let model = makeModel(
            provider: provider,
            maxWait: .seconds(30),
            activePollStaleAfter: 0.2  // 200ms — far shorter than fetchJobDelay
        )

        try await model.submit(url: "https://www.gimmesomeoven.com/authentic-gazpacho-recipe/")
        // The first poll is still in flight (2s delay) — reconcile() right
        // away must NOT start a second one; its entry isn't stale yet.
        model.reconcile()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(provider.callCount, 1, "not yet stale — reconcile() must not start a redundant poll")

        // Once the entry is older than activePollStaleAfter, reconcile() must
        // try again even though the original poll (still 2s from resolving)
        // hasn't cleared activePolls yet.
        try? await Task.sleep(for: .milliseconds(250))
        model.reconcile()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(provider.callCount, 2, "stale — reconcile() must start a fresh poll rather than skip forever")
    }
}
