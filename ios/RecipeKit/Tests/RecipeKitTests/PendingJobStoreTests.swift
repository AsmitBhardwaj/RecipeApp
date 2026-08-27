//
//  PendingJobStoreTests.swift
//  RecipeKitTests
//
//  The three deferred job-tracking edge cases. They exercise `PendingJobStore` —
//  the durable, App-Group-backed state that survives a force-quit and that the
//  app's `reconcile()` re-reads on relaunch to resume polling. A "relaunch" is
//  modeled as a FRESH store instance over the same persisted defaults (the store
//  is stateless; all state lives in UserDefaults), which is exactly what a new
//  process sees.
//

import XCTest
@testable import RecipeKit

final class PendingJobStoreTests: XCTestCase {

    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "pendingjobs-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func store() -> PendingJobStore { PendingJobStore(defaults: defaults) }

    // MARK: 1 — force-quit mid-poll recovers on relaunch

    func testForceQuitMidPollRecoversOnRelaunch() {
        // A job the app was actively polling when it was killed: persisted in a
        // non-terminal state.
        let writer = store()
        writer.upsert(PendingJob(jobId: "j1", url: "https://ig/1", lastStatus: .queued))
        writer.updateStatus(jobId: "j1", .processing)  // mid-poll

        // Relaunch: a brand-new store over the same persisted defaults.
        let afterRelaunch = store()
        let recovered = afterRelaunch.all()
        XCTAssertEqual(recovered.count, 1, "the in-flight job must survive the force-quit")
        XCTAssertEqual(recovered.first?.jobId, "j1")
        XCTAssertEqual(recovered.first?.lastStatus, .processing,
                       "its last-known status is preserved so reconcile() knows to resume")
    }

    // MARK: 2 — two jobs queued in sequence don't interfere

    func testTwoJobsQueuedInSequenceDoNotInterfere() {
        let s = store()
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        s.upsert(PendingJob(jobId: "a", url: "https://ig/a", submittedAt: older, lastStatus: .queued))
        s.upsert(PendingJob(jobId: "b", url: "https://ig/b", submittedAt: newer, lastStatus: .queued))

        // Both tracked, newest submission first.
        XCTAssertEqual(s.all().map(\.jobId), ["b", "a"])

        // Advancing/finishing one leaves the other exactly as it was.
        s.updateStatus(jobId: "a", .processing)
        s.remove(jobId: "a")  // 'a' completes and is cleared
        let remaining = s.all()
        XCTAssertEqual(remaining.map(\.jobId), ["b"])
        XCTAssertEqual(remaining.first?.lastStatus, .queued, "job b is untouched by a's lifecycle")

        // updateStatus on a now-absent job is a safe no-op (doesn't resurrect it
        // or corrupt b).
        s.updateStatus(jobId: "a", .complete)
        XCTAssertEqual(s.all().map(\.jobId), ["b"])
    }

    // MARK: 3 — failed-job cleanup

    func testFailedJobIsCleanedUpWithoutCorruptingOthers() {
        let s = store()
        s.upsert(PendingJob(jobId: "ok", url: "https://ig/ok", submittedAt: Date(timeIntervalSince1970: 1), lastStatus: .queued))
        s.upsert(PendingJob(jobId: "bad", url: "https://ig/bad", submittedAt: Date(timeIntervalSince1970: 2), lastStatus: .queued))

        // The extraction fails: marked failed, then removed (the app surfaces the
        // failure alert and clears the card).
        s.updateStatus(jobId: "bad", .failed)
        XCTAssertEqual(s.all().first(where: { $0.jobId == "bad" })?.lastStatus, .failed)

        s.remove(jobId: "bad")

        // Gone, doesn't linger, and the healthy job is intact.
        let after = s.all()
        XCTAssertEqual(after.map(\.jobId), ["ok"])
        XCTAssertEqual(after.first?.lastStatus, .queued)

        // And it stays gone across a relaunch (no resurrection from stale state).
        XCTAssertNil(store().all().first(where: { $0.jobId == "bad" }))
    }
}
