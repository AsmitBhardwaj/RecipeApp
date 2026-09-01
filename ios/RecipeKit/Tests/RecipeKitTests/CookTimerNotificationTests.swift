//
//  CookTimerNotificationTests.swift
//  RecipeKitTests
//
//  Covers slice 5's notification logic without triggering any OS notification:
//  the pure `CookTimer → CookTimerNotification` mapping (fires off
//  effectiveFinish, nil when paused/expired), and the scheduler lifecycle
//  (start requests permission + schedules, resume reschedules off the NEW
//  finish, pause/reset cancel). A spy stands in for the OS center and records
//  every call with its fire date.
//
//  All time is injected (`now:`); nothing here sleeps or hits UNUserNotificationCenter.
//

import XCTest
@testable import RecipeKit

// MARK: - Spy

private final class SpyNotificationCenter: CookTimerNotificationScheduling {
    var authorizationRequests = 0
    private(set) var scheduled: [CookTimerNotification] = []
    private(set) var cancelledIdentifiers: [[String]] = []

    func requestAuthorization() { authorizationRequests += 1 }
    func schedule(_ notification: CookTimerNotification) { scheduled.append(notification) }
    func cancelNotifications(identifiers: [String]) { cancelledIdentifiers.append(identifiers) }

    /// Flattened view of every id ever asked to cancel.
    var allCancelled: [String] { cancelledIdentifiers.flatMap { $0 } }
}

final class CookTimerNotificationTests: XCTestCase {

    private let recipe = "r1"
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func runningTimer(step: Int = 1, duration: Int = 300, accumulated: TimeInterval = 0) -> CookTimer {
        CookTimer(recipeId: recipe, stepNumber: step, durationSeconds: duration,
                  startedAt: t0, accumulatedElapsed: accumulated)
    }

    // MARK: - Pure mapping

    func testRunningTimerPlansAlertAtEffectiveFinish() {
        let timer = runningTimer(duration: 300, accumulated: 60)   // finish = t0 + 240
        let plan = timer.plannedNotification(asOf: t0)
        XCTAssertEqual(plan?.fireDate, t0.addingTimeInterval(240))
        XCTAssertEqual(plan?.identifier, "cook-timer-\(recipe)|1")
        XCTAssertEqual(plan?.body, "Step 1 is ready.")
    }

    func testPausedTimerPlansNothing() {
        let paused = runningTimer().paused(asOf: t0.addingTimeInterval(30))
        XCTAssertNil(paused.plannedNotification(asOf: t0.addingTimeInterval(30)))
    }

    func testExpiredTimerInThePastPlansNothing() {
        let timer = runningTimer(duration: 60)          // finish = t0 + 60
        XCTAssertNil(timer.plannedNotification(asOf: t0.addingTimeInterval(90)))
    }

    func testCustomBodyOverridesDefault() {
        let plan = runningTimer().plannedNotification(asOf: t0, body: "Simmer the sauce is done")
        XCTAssertEqual(plan?.body, "Simmer the sauce is done")
    }

    func testIdentifierIsStableAcrossRunningState() {
        let running = runningTimer(step: 2)
        let paused = running.paused(asOf: t0.addingTimeInterval(10))
        XCTAssertEqual(running.notificationIdentifier, paused.notificationIdentifier)
        XCTAssertEqual(running.notificationIdentifier, "cook-timer-\(recipe)|2")
    }

    // MARK: - Scheduler lifecycle

    func testStartRequestsPermissionAndSchedules() {
        let spy = SpyNotificationCenter()
        let scheduler = CookTimerNotificationScheduler(center: spy)

        scheduler.timerStarted(runningTimer(duration: 300), now: t0)

        XCTAssertEqual(spy.authorizationRequests, 1)
        XCTAssertEqual(spy.scheduled.count, 1)
        XCTAssertEqual(spy.scheduled.first?.fireDate, t0.addingTimeInterval(300))
    }

    func testResumeDoesNotRequestPermissionAgainAndReschedulesOffNewFinish() {
        let spy = SpyNotificationCenter()
        let scheduler = CookTimerNotificationScheduler(center: spy)

        // Start, then pause after 50s (100s in original finish was t0+300).
        let started = runningTimer(duration: 300)
        scheduler.timerStarted(started, now: t0)
        let paused = started.paused(asOf: t0.addingTimeInterval(50))
        scheduler.timerPaused(paused)

        // Resume much later; new finish = resumeNow + (300 - 50) = t1 + 250.
        let t1 = t0.addingTimeInterval(10_000)
        let resumed = paused.resumed(asOf: t1)
        scheduler.timerResumed(resumed, now: t1)

        // Permission only requested at start.
        XCTAssertEqual(spy.authorizationRequests, 1)
        // Latest schedule reflects the shifted finish, not the original.
        XCTAssertEqual(spy.scheduled.last?.fireDate, t1.addingTimeInterval(250))
        // The stale alert was cancelled before rescheduling (by the same id).
        XCTAssertTrue(spy.allCancelled.contains("cook-timer-\(recipe)|1"))
    }

    func testPauseCancelsAndSchedulesNothingNew() {
        let spy = SpyNotificationCenter()
        let scheduler = CookTimerNotificationScheduler(center: spy)

        let started = runningTimer()
        scheduler.timerStarted(started, now: t0)
        let scheduledAfterStart = spy.scheduled.count

        scheduler.timerPaused(started.paused(asOf: t0.addingTimeInterval(30)))

        XCTAssertEqual(spy.scheduled.count, scheduledAfterStart)   // no new schedule
        XCTAssertTrue(spy.allCancelled.contains("cook-timer-\(recipe)|1"))
    }

    func testResetCancels() {
        let spy = SpyNotificationCenter()
        let scheduler = CookTimerNotificationScheduler(center: spy)

        let started = runningTimer()
        scheduler.timerStarted(started, now: t0)
        scheduler.timerReset(started.reset())

        XCTAssertTrue(spy.allCancelled.contains("cook-timer-\(recipe)|1"))
    }

    func testStartingAnAlreadyExpiredTimerSchedulesNothingButStillCancelsStale() {
        let spy = SpyNotificationCenter()
        let scheduler = CookTimerNotificationScheduler(center: spy)

        // A 60s timer, but "now" is already past its finish.
        scheduler.timerStarted(runningTimer(duration: 60), now: t0.addingTimeInterval(120))

        XCTAssertEqual(spy.authorizationRequests, 1)
        XCTAssertTrue(spy.scheduled.isEmpty)                        // nothing to fire
        XCTAssertFalse(spy.allCancelled.isEmpty)                   // stale cleared defensively
    }

    func testCancelByIdWithoutATimerValue() {
        let spy = SpyNotificationCenter()
        let scheduler = CookTimerNotificationScheduler(center: spy)

        scheduler.cancel(recipeId: recipe, stepNumber: 3)
        XCTAssertEqual(spy.allCancelled, ["cook-timer-\(recipe)|3"])
    }

    func testConcurrentTimersScheduleIndependentIdentifiers() {
        let spy = SpyNotificationCenter()
        let scheduler = CookTimerNotificationScheduler(center: spy)

        scheduler.timerStarted(runningTimer(step: 1, duration: 300), now: t0)
        scheduler.timerStarted(runningTimer(step: 4, duration: 60), now: t0)

        let ids = Set(spy.scheduled.map { $0.identifier })
        XCTAssertEqual(ids, ["cook-timer-\(recipe)|1", "cook-timer-\(recipe)|4"])
    }
}
