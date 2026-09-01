//
//  CookTimerStore.swift
//  RecipeKit
//
//  Persistence for Cook Mode step timers — a single JSON-encoded
//  `[String: CookTimer]` (keyed by "recipeId|step") under one key, the same
//  lightweight App Group `UserDefaults` pattern as `MealPlanStore` /
//  `GroceryCheckStore`. Because each `CookTimer` is timestamp-based, persisting
//  it is enough for the countdown to survive navigating between steps, exiting
//  Cook Mode, backgrounding, and a force-quit/relaunch: the remaining time is
//  re-derived from the wall clock whenever it's read.
//
//  This slice is the store only. It manages timer STATE; the notification that
//  a pause cancels or a resume reschedules is wired in slice 5. Multiple timers
//  may run at once (no cap for Stage 1).
//

import Foundation

public struct CookTimerStore {

    /// Key holding the JSON-encoded `[String: CookTimer]`. Namespaced by account
    /// when a `userScope` is given (Stage 2b), legacy key otherwise.
    private static let baseKey = "cook_timers_v1"
    private let storageKey: String

    private let defaults: UserDefaults

    /// Production initializer. Falls back to `.standard` if the App Group suite
    /// can't be opened, so timers degrade to app-local rather than crashing.
    public init(suiteName: String = AppGroup.identifier, userScope: String? = nil) {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
        self.storageKey = scopedStorageKey(Self.baseKey, userScope)
    }

    /// Test/seam initializer: inject an ephemeral `UserDefaults` for host tests.
    public init(defaults: UserDefaults, userScope: String? = nil) {
        self.defaults = defaults
        self.storageKey = scopedStorageKey(Self.baseKey, userScope)
    }

    // MARK: - Reads

    /// Every timer across all recipes/steps, keyed by "recipeId|step".
    public func all() -> [String: CookTimer] {
        guard let data = defaults.data(forKey: storageKey) else { return [:] }
        return (try? JSONDecoder().decode([String: CookTimer].self, from: data)) ?? [:]
    }

    /// The timer for one step, or nil if none has been created/started yet.
    public func timer(recipeId: String, stepNumber: Int) -> CookTimer? {
        all()[CookTimer.key(recipeId: recipeId, stepNumber: stepNumber)]
    }

    // MARK: - Writes

    /// Begin a fresh run of a step's timer: running, from `now`, nothing
    /// elapsed. Overwrites any existing timer for the step (e.g. restarting an
    /// expired one). Returns the created timer for the caller's convenience.
    @discardableResult
    public func start(
        recipeId: String,
        stepNumber: Int,
        durationSeconds: Int,
        now: Date = Date()
    ) -> CookTimer {
        let timer = CookTimer(
            recipeId: recipeId,
            stepNumber: stepNumber,
            durationSeconds: durationSeconds,
            startedAt: now,
            accumulatedElapsed: 0
        )
        upsert(timer)
        return timer
    }

    /// Pause a running step timer. No-op if absent or already paused.
    public func pause(recipeId: String, stepNumber: Int, now: Date = Date()) {
        mutate(recipeId: recipeId, stepNumber: stepNumber) { $0.paused(asOf: now) }
    }

    /// Resume a paused step timer from `now`. No-op if absent or already running.
    public func resume(recipeId: String, stepNumber: Int, now: Date = Date()) {
        mutate(recipeId: recipeId, stepNumber: stepNumber) { $0.resumed(asOf: now) }
    }

    /// Reset a step timer back to full duration, stopped. No-op if absent.
    public func reset(recipeId: String, stepNumber: Int) {
        mutate(recipeId: recipeId, stepNumber: stepNumber) { $0.reset() }
    }

    /// Remove a step timer from the store entirely.
    public func remove(recipeId: String, stepNumber: Int) {
        var timers = all()
        timers.removeValue(forKey: CookTimer.key(recipeId: recipeId, stepNumber: stepNumber))
        write(timers)
    }

    /// Drop every timer — e.g. when leaving Cook Mode wants a clean slate.
    public func clear() {
        defaults.removeObject(forKey: storageKey)
    }

    // MARK: - Internals

    /// Apply a pure transition to one timer and persist the result. No-op when
    /// no timer exists for the key, so callers don't guard first.
    private func mutate(
        recipeId: String,
        stepNumber: Int,
        _ transform: (CookTimer) -> CookTimer
    ) {
        var timers = all()
        let key = CookTimer.key(recipeId: recipeId, stepNumber: stepNumber)
        guard let existing = timers[key] else { return }
        timers[key] = transform(existing)
        write(timers)
    }

    private func upsert(_ timer: CookTimer) {
        var timers = all()
        timers[timer.key] = timer
        write(timers)
    }

    private func write(_ timers: [String: CookTimer]) {
        guard let data = try? JSONEncoder().encode(timers) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
