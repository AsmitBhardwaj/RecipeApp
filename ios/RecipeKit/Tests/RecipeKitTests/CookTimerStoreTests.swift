//
//  CookTimerStoreTests.swift
//  RecipeKitTests
//
//  Covers the Cook Mode timer store and its timestamp model: the derived
//  remaining/elapsed math, the pause/resume/reset transitions, concurrent
//  timers, and — the point of a timestamp design — a simulated relaunch where a
//  running timer keeps counting down across a fresh store instance.
//
//  All time is injected (`now:`) so nothing here sleeps or depends on wall time.
//

import XCTest
@testable import RecipeKit

final class CookTimerStoreTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "cook-timer-tests-\(UUID().uuidString)")!
    }

    private let recipe = "r1"
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - Model math

    func testFreshRunningTimerCountsDownFromDuration() {
        let timer = CookTimer(
            recipeId: recipe, stepNumber: 1, durationSeconds: 300,
            startedAt: t0, accumulatedElapsed: 0
        )
        XCTAssertEqual(timer.remaining(asOf: t0), 300)
        XCTAssertEqual(timer.remaining(asOf: t0.addingTimeInterval(120)), 180)
        XCTAssertTrue(timer.isRunning)
        XCTAssertFalse(timer.isExpired(asOf: t0.addingTimeInterval(120)))
    }

    func testExpiryAndOverrunGoNegative() {
        let timer = CookTimer(
            recipeId: recipe, stepNumber: 1, durationSeconds: 60, startedAt: t0
        )
        XCTAssertTrue(timer.isExpired(asOf: t0.addingTimeInterval(60)))
        XCTAssertEqual(timer.remaining(asOf: t0.addingTimeInterval(90)), -30)
    }

    func testBackwardClockDoesNotRunTimerBackwards() {
        let timer = CookTimer(
            recipeId: recipe, stepNumber: 1, durationSeconds: 300, startedAt: t0
        )
        // now earlier than startedAt → current-run elapsed floored at 0.
        XCTAssertEqual(timer.remaining(asOf: t0.addingTimeInterval(-50)), 300)
    }

    func testEffectiveFinishIsStableAndNilWhenPaused() {
        let running = CookTimer(
            recipeId: recipe, stepNumber: 1, durationSeconds: 300,
            startedAt: t0, accumulatedElapsed: 60
        )
        // startedAt + (300 - 60) = t0 + 240.
        XCTAssertEqual(running.effectiveFinish, t0.addingTimeInterval(240))

        let paused = running.paused(asOf: t0.addingTimeInterval(30))
        XCTAssertNil(paused.effectiveFinish)
    }

    // MARK: - Transitions

    func testPauseFoldsElapsedAndStops() {
        let running = CookTimer(
            recipeId: recipe, stepNumber: 1, durationSeconds: 300, startedAt: t0
        )
        let paused = running.paused(asOf: t0.addingTimeInterval(75))
        XCTAssertFalse(paused.isRunning)
        XCTAssertEqual(paused.accumulatedElapsed, 75)
        // Remaining is frozen while paused, regardless of how far `now` moves.
        XCTAssertEqual(paused.remaining(asOf: t0.addingTimeInterval(9999)), 225)
    }

    func testResumeKeepsAccumulationAndRestartsClock() {
        let paused = CookTimer(
            recipeId: recipe, stepNumber: 1, durationSeconds: 300,
            startedAt: nil, accumulatedElapsed: 75
        )
        let t1 = t0.addingTimeInterval(1000)
        let resumed = paused.resumed(asOf: t1)
        XCTAssertTrue(resumed.isRunning)
        XCTAssertEqual(resumed.startedAt, t1)
        // 75 already elapsed; 25 more after resume ⇒ 200 remaining.
        XCTAssertEqual(resumed.remaining(asOf: t1.addingTimeInterval(25)), 200)
    }

    func testPauseResumeAreNoOpsInWrongState() {
        let running = CookTimer(recipeId: recipe, stepNumber: 1, durationSeconds: 300, startedAt: t0)
        XCTAssertEqual(running.resumed(asOf: t0.addingTimeInterval(5)), running)

        let paused = running.paused(asOf: t0.addingTimeInterval(30))
        XCTAssertEqual(paused.paused(asOf: t0.addingTimeInterval(40)), paused)
    }

    func testResetZeroesEverything() {
        let running = CookTimer(
            recipeId: recipe, stepNumber: 1, durationSeconds: 300,
            startedAt: t0, accumulatedElapsed: 40
        )
        let reset = running.reset()
        XCTAssertFalse(reset.isRunning)
        XCTAssertEqual(reset.accumulatedElapsed, 0)
        XCTAssertEqual(reset.remaining(asOf: t0.addingTimeInterval(9999)), 300)
    }

    // MARK: - Store persistence

    func testStartPersistsARunningTimer() {
        let store = CookTimerStore(defaults: makeDefaults())
        store.start(recipeId: recipe, stepNumber: 2, durationSeconds: 180, now: t0)

        let loaded = store.timer(recipeId: recipe, stepNumber: 2)
        XCTAssertEqual(loaded?.durationSeconds, 180)
        XCTAssertEqual(loaded?.startedAt, t0)
        XCTAssertEqual(loaded?.remaining(asOf: t0.addingTimeInterval(30)), 150)
    }

    func testPauseResumeResetRoundTripThroughStore() {
        let store = CookTimerStore(defaults: makeDefaults())
        store.start(recipeId: recipe, stepNumber: 1, durationSeconds: 300, now: t0)

        store.pause(recipeId: recipe, stepNumber: 1, now: t0.addingTimeInterval(50))
        XCTAssertEqual(store.timer(recipeId: recipe, stepNumber: 1)?.accumulatedElapsed, 50)
        XCTAssertFalse(store.timer(recipeId: recipe, stepNumber: 1)?.isRunning ?? true)

        let t1 = t0.addingTimeInterval(500)
        store.resume(recipeId: recipe, stepNumber: 1, now: t1)
        XCTAssertEqual(store.timer(recipeId: recipe, stepNumber: 1)?.startedAt, t1)
        XCTAssertEqual(store.timer(recipeId: recipe, stepNumber: 1)?.remaining(asOf: t1.addingTimeInterval(50)), 200)

        store.reset(recipeId: recipe, stepNumber: 1)
        let reset = store.timer(recipeId: recipe, stepNumber: 1)
        XCTAssertEqual(reset?.accumulatedElapsed, 0)
        XCTAssertNil(reset?.startedAt)
    }

    func testTransitionsOnMissingTimerAreNoOps() {
        let store = CookTimerStore(defaults: makeDefaults())
        // None of these should create anything or crash.
        store.pause(recipeId: recipe, stepNumber: 9, now: t0)
        store.resume(recipeId: recipe, stepNumber: 9, now: t0)
        store.reset(recipeId: recipe, stepNumber: 9)
        XCTAssertNil(store.timer(recipeId: recipe, stepNumber: 9))
        XCTAssertTrue(store.all().isEmpty)
    }

    func testConcurrentTimersAreIndependent() {
        let store = CookTimerStore(defaults: makeDefaults())
        store.start(recipeId: recipe, stepNumber: 1, durationSeconds: 300, now: t0)
        store.start(recipeId: recipe, stepNumber: 3, durationSeconds: 60, now: t0)
        store.start(recipeId: "r2", stepNumber: 1, durationSeconds: 120, now: t0)

        // Pausing one leaves the others running.
        store.pause(recipeId: recipe, stepNumber: 1, now: t0.addingTimeInterval(10))
        XCTAssertFalse(store.timer(recipeId: recipe, stepNumber: 1)?.isRunning ?? true)
        XCTAssertTrue(store.timer(recipeId: recipe, stepNumber: 3)?.isRunning ?? false)
        XCTAssertTrue(store.timer(recipeId: "r2", stepNumber: 1)?.isRunning ?? false)
        XCTAssertEqual(store.all().count, 3)

        store.remove(recipeId: recipe, stepNumber: 3)
        XCTAssertEqual(store.all().count, 2)
        XCTAssertNil(store.timer(recipeId: recipe, stepNumber: 3))
    }

    func testAccountScopingKeepsTimersSeparate() {
        let defaults = makeDefaults()
        let alice = CookTimerStore(defaults: defaults, userScope: "alice")
        let bob = CookTimerStore(defaults: defaults, userScope: "bob")

        alice.start(recipeId: recipe, stepNumber: 1, durationSeconds: 300, now: t0)
        XCTAssertNotNil(alice.timer(recipeId: recipe, stepNumber: 1))
        XCTAssertNil(bob.timer(recipeId: recipe, stepNumber: 1))
    }

    // MARK: - Simulated relaunch

    /// The core promise of the timestamp design: a running timer, persisted and
    /// then read back through a BRAND-NEW store instance (as after a force-quit
    /// and relaunch) keeps counting down from wall-clock time — nothing needed
    /// to be ticking in between.
    func testRunningTimerSurvivesRelaunchAndKeepsCountingDown() {
        let defaults = makeDefaults()

        // First launch: start a 5-minute timer.
        do {
            let store = CookTimerStore(defaults: defaults)
            store.start(recipeId: recipe, stepNumber: 1, durationSeconds: 300, now: t0)
        }

        // ...force-quit, and relaunch 2 minutes later with a fresh instance.
        let relaunch = CookTimerStore(defaults: defaults)
        let twoMinutesLater = t0.addingTimeInterval(120)
        let timer = relaunch.timer(recipeId: recipe, stepNumber: 1)
        XCTAssertEqual(timer?.isRunning, true)
        XCTAssertEqual(timer?.remaining(asOf: twoMinutesLater), 180)

        // And a timer that would have fired while the app was dead reads expired.
        let sixMinutesLater = t0.addingTimeInterval(360)
        XCTAssertEqual(timer?.isExpired(asOf: sixMinutesLater), true)
    }

    /// A paused timer's remaining time must NOT drift across a relaunch — the
    /// folded accumulation is frozen no matter how much wall time passed.
    func testPausedTimerDoesNotDriftAcrossRelaunch() {
        let defaults = makeDefaults()
        do {
            let store = CookTimerStore(defaults: defaults)
            store.start(recipeId: recipe, stepNumber: 1, durationSeconds: 300, now: t0)
            store.pause(recipeId: recipe, stepNumber: 1, now: t0.addingTimeInterval(45))
        }

        let relaunch = CookTimerStore(defaults: defaults)
        let muchLater = t0.addingTimeInterval(100_000)
        XCTAssertEqual(relaunch.timer(recipeId: recipe, stepNumber: 1)?.remaining(asOf: muchLater), 255)
    }
}
