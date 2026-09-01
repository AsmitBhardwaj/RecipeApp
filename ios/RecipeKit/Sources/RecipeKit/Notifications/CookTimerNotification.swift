//
//  CookTimerNotification.swift
//  RecipeKit
//
//  The pure plan for one Cook Mode step-timer alert: what to fire, when. This
//  is the testable core of slice 5 — it maps a `CookTimer` to the notification
//  that should be pending for it, with no reference to UNUserNotificationCenter
//  or any OS type, so the scheduling logic can be verified without triggering a
//  real notification.
//
//  A notification is planned off `CookTimer.effectiveFinish` — the wall-clock
//  instant a RUNNING timer hits zero. A paused/stopped timer has no finish
//  instant (nil), and an already-expired one is in the past, so neither yields
//  a plan: the mapper returns nil and the scheduler cancels instead.
//

import Foundation

/// A single pending step-timer alert, addressed by a stable identifier so a
/// reschedule (resume) replaces the prior one rather than stacking.
public struct CookTimerNotification: Equatable {
    public let identifier: String
    /// Absolute wall-clock instant to fire — `CookTimer.effectiveFinish`.
    public let fireDate: Date
    public let title: String
    public let body: String

    public init(identifier: String, fireDate: Date, title: String, body: String) {
        self.identifier = identifier
        self.fireDate = fireDate
        self.title = title
        self.body = body
    }
}

public extension CookTimer {

    /// Stable notification identifier for this step's timer, independent of
    /// whether it's currently running — so pause/reset can cancel by the same
    /// id that start/resume scheduled under.
    static func notificationIdentifier(recipeId: String, stepNumber: Int) -> String {
        "cook-timer-\(key(recipeId: recipeId, stepNumber: stepNumber))"
    }

    var notificationIdentifier: String {
        Self.notificationIdentifier(recipeId: recipeId, stepNumber: stepNumber)
    }

    /// The alert that should be pending for this timer as of `now`, or nil when
    /// nothing should be scheduled: the timer is paused/stopped (no
    /// `effectiveFinish`) or its finish is already in the past (expired — it
    /// stays "Done" in the UI, but no notification fires).
    ///
    /// `title`/`body` default to a generic step message; slice 6 can pass richer
    /// copy (recipe name, etc.) without changing the scheduling logic.
    func plannedNotification(
        asOf now: Date = Date(),
        title: String = "Timer done",
        body: String? = nil
    ) -> CookTimerNotification? {
        guard let fireDate = effectiveFinish, fireDate > now else { return nil }
        return CookTimerNotification(
            identifier: notificationIdentifier,
            fireDate: fireDate,
            title: title,
            body: body ?? "Step \(stepNumber) is ready."
        )
    }
}
