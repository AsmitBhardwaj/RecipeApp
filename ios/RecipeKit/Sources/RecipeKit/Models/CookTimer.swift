//
//  CookTimer.swift
//  RecipeKit
//
//  One Cook Mode step timer, modelled as timestamps rather than a ticking
//  counter so it stays correct across backgrounding, exiting Cook Mode, and a
//  force-quit/relaunch — nothing needs to have been running in between.
//
//  A running timer stores the wall-clock `startedAt` of its current run plus
//  `accumulatedElapsed`, the time folded in from all previous (paused) runs.
//  Remaining time is always derived from `Date()` at read time, never stored,
//  so a value that was persisted an hour ago reads back with the hour counted.
//
//  Pause folds the current run's elapsed into `accumulatedElapsed` and clears
//  `startedAt`; resume sets a fresh `startedAt` and keeps the accumulation;
//  reset zeroes both. (The matching notification scheduling lives in slice 5 —
//  this type is pure state.)
//

import Foundation

public struct CookTimer: Codable, Hashable {

    /// Recipe this step belongs to — half of the store key.
    public let recipeId: String
    /// 1-based step number — the other half of the store key.
    public let stepNumber: Int
    /// The countdown target, fixed when the timer is created.
    public let durationSeconds: Int

    /// Start of the CURRENT run, or nil when paused/stopped. Non-nil ⇒ running.
    public var startedAt: Date?
    /// Elapsed time folded in from earlier runs (grows on each pause).
    public var accumulatedElapsed: TimeInterval

    public init(
        recipeId: String,
        stepNumber: Int,
        durationSeconds: Int,
        startedAt: Date? = nil,
        accumulatedElapsed: TimeInterval = 0
    ) {
        self.recipeId = recipeId
        self.stepNumber = stepNumber
        self.durationSeconds = durationSeconds
        self.startedAt = startedAt
        self.accumulatedElapsed = accumulatedElapsed
    }

    /// Composite store key. Kept here so the store and any caller agree on it.
    public static func key(recipeId: String, stepNumber: Int) -> String {
        "\(recipeId)|\(stepNumber)"
    }

    public var key: String { Self.key(recipeId: recipeId, stepNumber: stepNumber) }

    // MARK: - Derived state (never persisted)

    public var isRunning: Bool { startedAt != nil }

    /// Total time counted against the duration as of `now`. The current run's
    /// contribution is floored at 0 so a clock that jumped backwards can't make
    /// the timer run backwards.
    public func elapsed(asOf now: Date = Date()) -> TimeInterval {
        let live = startedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
        return accumulatedElapsed + live
    }

    /// Seconds left, negative once overdue.
    public func remaining(asOf now: Date = Date()) -> TimeInterval {
        Double(durationSeconds) - elapsed(asOf: now)
    }

    /// True once the timer has counted down to (or past) zero.
    public func isExpired(asOf now: Date = Date()) -> Bool {
        remaining(asOf: now) <= 0
    }

    /// The wall-clock instant this timer hits zero while running — what slice 5
    /// schedules the local notification off of. nil when paused/stopped.
    ///
    /// Independent of `now`: it's `startedAt + (duration − accumulated)`.
    public var effectiveFinish: Date? {
        guard let startedAt else { return nil }
        return startedAt.addingTimeInterval(Double(durationSeconds) - accumulatedElapsed)
    }

    // MARK: - Transitions (pure — return a new value, never mutate persistence)

    /// Fold the running elapsed into the accumulation and stop the clock.
    /// No-op if already paused.
    public func paused(asOf now: Date = Date()) -> CookTimer {
        guard startedAt != nil else { return self }
        var copy = self
        copy.accumulatedElapsed = elapsed(asOf: now)
        copy.startedAt = nil
        return copy
    }

    /// Start the clock again from `now`, keeping prior accumulation. No-op if
    /// already running.
    public func resumed(asOf now: Date = Date()) -> CookTimer {
        guard startedAt == nil else { return self }
        var copy = self
        copy.startedAt = now
        return copy
    }

    /// Back to the untouched, stopped state: full duration, nothing elapsed.
    public func reset() -> CookTimer {
        var copy = self
        copy.startedAt = nil
        copy.accumulatedElapsed = 0
        return copy
    }
}
