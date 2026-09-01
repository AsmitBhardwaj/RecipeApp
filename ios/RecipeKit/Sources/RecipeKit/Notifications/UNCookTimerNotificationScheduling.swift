//
//  UNCookTimerNotificationScheduling.swift
//  RecipeKit
//
//  Production adapter: the `CookTimerNotificationScheduling` seam backed by the
//  real `UNUserNotificationCenter`. This is the ONLY file that imports
//  UserNotifications or references the OS center. It is constructed by the app
//  (slice 6); the host unit tests use a spy instead, so they never call
//  `UNUserNotificationCenter.current()` (which traps outside an app bundle).
//
//  Deliberately NOT a `UNUserNotificationCenterDelegate`: firing an alert must
//  not mutate timer state. Delegate wiring (foreground presentation options,
//  etc.) belongs with the app in slice 6.
//

import Foundation
import UserNotifications

public struct UNCookTimerNotificationScheduling: CookTimerNotificationScheduling {

    private let center: UNUserNotificationCenter

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    public func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    public func schedule(_ notification: CookTimerNotification) {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default

        // Fire at the absolute finish instant. A calendar trigger off the exact
        // date is robust to how far ahead it was scheduled; non-repeating.
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: notification.fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

        let request = UNNotificationRequest(
            identifier: notification.identifier,
            content: content,
            trigger: trigger
        )
        // Re-adding with the same identifier replaces any pending copy.
        center.add(request)
    }

    public func cancelNotifications(identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}
