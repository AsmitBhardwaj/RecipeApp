//
//  CookTimerNotificationScheduler.swift
//  RecipeKit
//
//  Maps Cook Mode timer lifecycle events to OS notification calls, off
//  `CookTimer.effectiveFinish` (slice 4). It coordinates only notifications —
//  it never reads or writes `CookTimerStore`. In particular, a notification
//  FIRING does nothing here: there is no notification-center delegate in this
//  type, so an expired timer's alert never mutates timer state. The timer stays
//  visible as 00:00 / "Done" until the user resets it or revisits the step.
//
//  The four lifecycle methods mirror the timer transitions 1:1:
//    • started  → request permission (first start), then schedule off finish
//    • resumed  → reschedule off the NEW finish
//    • paused   → cancel (a paused timer has no finish)
//    • reset    → cancel
//
//  Scheduling ("cancel any stale alert, then schedule fresh if the timer is
//  running and its finish is still in the future") is unified in `sync`.
//

import Foundation

public final class CookTimerNotificationScheduler {

    private let center: CookTimerNotificationScheduling

    public init(center: CookTimerNotificationScheduling) {
        self.center = center
    }

    /// Call when a timer is first started. Requests permission (the OS prompts
    /// only once, on first start — never on Cook Mode entry, since nothing calls
    /// this before a start), then schedules the alert.
    public func timerStarted(_ timer: CookTimer, now: Date = Date(), body: String? = nil) {
        center.requestAuthorization()
        sync(timer, now: now, body: body)
    }

    /// Call when a paused timer is resumed — reschedules off the new finish.
    public func timerResumed(_ timer: CookTimer, now: Date = Date(), body: String? = nil) {
        sync(timer, now: now, body: body)
    }

    /// Call when a timer is paused — cancels its pending alert (it has no finish
    /// while paused).
    public func timerPaused(_ timer: CookTimer) {
        cancel(timer)
    }

    /// Call when a timer is reset — cancels its pending alert entirely.
    public func timerReset(_ timer: CookTimer) {
        cancel(timer)
    }

    /// Cancel a timer's pending alert by identity (running state irrelevant).
    public func cancel(_ timer: CookTimer) {
        center.cancelNotifications(identifiers: [timer.notificationIdentifier])
    }

    /// Cancel by identity when no `CookTimer` value is at hand (e.g. tearing
    /// down a step whose timer was already removed from the store).
    public func cancel(recipeId: String, stepNumber: Int) {
        center.cancelNotifications(
            identifiers: [CookTimer.notificationIdentifier(recipeId: recipeId, stepNumber: stepNumber)]
        )
    }

    // MARK: - Internals

    /// Replace any stale alert for this timer, then schedule a fresh one iff the
    /// timer is running and its finish is still in the future. A paused, reset,
    /// or already-expired timer yields no plan, so this reduces to a cancel.
    private func sync(_ timer: CookTimer, now: Date, body: String?) {
        center.cancelNotifications(identifiers: [timer.notificationIdentifier])
        if let plan = timer.plannedNotification(asOf: now, body: body) {
            center.schedule(plan)
        }
    }
}
