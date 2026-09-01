//
//  CookModeModel.swift
//  RecipeApp
//
//  The coordinator behind the full-screen Cook Mode: which step is showing, and
//  the per-step timers. It's the single place the UI touches slices 4–5 —
//  `CookTimerStore` (persistence) and `CookTimerNotificationScheduler` (alerts)
//  are always driven together here so they never drift apart:
//    start  → store.start   + scheduler.timerStarted   (asks permission)
//    pause  → store.pause    + scheduler.timerPaused    (cancels the alert)
//    resume → store.resume   + scheduler.timerResumed   (reschedules)
//    reset  → store.reset     + scheduler.timerReset     (cancels)
//
//  Navigation (`currentIndex`, back/next) deliberately touches NO timer state:
//  stepping between steps or exiting Cook Mode entirely leaves running timers
//  running — they keep counting (timestamp-based) and keep their scheduled
//  notification, and re-open reads them back correctly counted-down.
//

import Foundation
import SwiftUI
import RecipeKit

@MainActor
final class CookModeModel: ObservableObject {

    let recipe: Recipe

    /// Index into `steps` of the visible step.
    @Published private(set) var currentIndex: Int = 0
    /// This recipe's timers, keyed by `CookTimer.key`, mirrored from the store
    /// so SwiftUI re-renders on start/pause/reset. (Countdown ticking is driven
    /// separately by a `TimelineView` in the UI, since remaining time is derived
    /// from the wall clock, not stored.)
    @Published private(set) var timers: [String: CookTimer] = [:]

    private let store: CookTimerStore
    private let scheduler: CookTimerNotificationScheduler

    init(recipe: Recipe, userScope: String?, scheduler: CookTimerNotificationScheduler) {
        self.recipe = recipe
        self.store = CookTimerStore(userScope: userScope)
        self.scheduler = scheduler
        reload()
    }

    // MARK: - Steps

    var steps: [Instruction] { recipe.instructions }
    var stepCount: Int { steps.count }
    var currentStep: Instruction? {
        steps.indices.contains(currentIndex) ? steps[currentIndex] : nil
    }

    var canGoBack: Bool { currentIndex > 0 }
    var canGoNext: Bool { currentIndex < stepCount - 1 }

    func goBack() { if canGoBack { currentIndex -= 1 } }
    func goNext() { if canGoNext { currentIndex += 1 } }

    /// Jump straight to a step by number (badge tap). No-op if not found.
    func goToStep(number: Int) {
        if let idx = steps.firstIndex(where: { $0.stepNumber == number }) {
            currentIndex = idx
        }
    }

    /// Set the visible step by index (paging swipe). Clamped to valid range.
    func goToStep(index: Int) {
        guard steps.indices.contains(index) else { return }
        currentIndex = index
    }

    // MARK: - Timer reads

    func timer(for step: Instruction) -> CookTimer? {
        timers[CookTimer.key(recipeId: recipe.recipeId, stepNumber: step.stepNumber)]
    }

    /// Running timers that haven't yet hit zero, soonest-to-finish first — what
    /// the persistent badge shows. Paused and already-expired ("Done") timers
    /// are not "counting down", so they don't appear.
    func activeTimers(asOf now: Date = Date()) -> [CookTimer] {
        timers.values
            .filter { $0.isRunning && !$0.isExpired(asOf: now) }
            .sorted { ($0.effectiveFinish ?? .distantFuture) < ($1.effectiveFinish ?? .distantFuture) }
    }

    // MARK: - Timer actions (store + scheduler, always together)

    /// Toggle the primary control: start a never-started timer, pause a running
    /// one, resume a paused one. No-op once expired (stays "Done" until reset).
    func togglePlayPause(for step: Instruction) {
        guard let duration = step.effectiveDurationSeconds else { return }
        switch timer(for: step) {
        case .none:
            start(step: step, duration: duration)
        case .some(let t) where t.isRunning:
            pause(step: step)
        case .some(let t) where t.isExpired():
            break // done; only Reset acts now
        case .some:
            resume(step: step)
        }
    }

    private func start(step: Instruction, duration: Int) {
        let timer = store.start(
            recipeId: recipe.recipeId, stepNumber: step.stepNumber, durationSeconds: duration
        )
        scheduler.timerStarted(timer, body: notificationBody(for: step))
        reload()
    }

    private func pause(step: Instruction) {
        store.pause(recipeId: recipe.recipeId, stepNumber: step.stepNumber)
        if let t = store.timer(recipeId: recipe.recipeId, stepNumber: step.stepNumber) {
            scheduler.timerPaused(t)
        }
        reload()
    }

    private func resume(step: Instruction) {
        store.resume(recipeId: recipe.recipeId, stepNumber: step.stepNumber)
        if let t = store.timer(recipeId: recipe.recipeId, stepNumber: step.stepNumber) {
            scheduler.timerResumed(t, body: notificationBody(for: step))
        }
        reload()
    }

    func reset(step: Instruction) {
        store.reset(recipeId: recipe.recipeId, stepNumber: step.stepNumber)
        if let t = store.timer(recipeId: recipe.recipeId, stepNumber: step.stepNumber) {
            scheduler.timerReset(t)
        }
        reload()
    }

    // MARK: - Internals

    /// Reload this recipe's timers from the store (drops other recipes').
    private func reload() {
        timers = store.all().filter { $0.value.recipeId == recipe.recipeId }
    }

    private func notificationBody(for step: Instruction) -> String {
        "Step \(step.stepNumber) of \(recipe.title) is ready."
    }
}
