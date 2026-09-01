//
//  CookTimerNotificationScheduling.swift
//  RecipeKit
//
//  The seam between the pure scheduling logic and the OS notification center.
//  `CookTimerNotificationScheduler` talks only to this protocol, so tests inject
//  a spy and assert the right calls happen with the right fire dates, while the
//  app injects the real `UNUserNotificationCenter`-backed adapter (which lives
//  in a separate file and is never touched by the host test target — calling
//  `UNUserNotificationCenter.current()` outside an app bundle would trap).
//

import Foundation

public protocol CookTimerNotificationScheduling {
    /// Ask for alert/sound permission. Idempotent at the OS level — the system
    /// only ever prompts once — so it's safe to call on every timer start.
    func requestAuthorization()

    /// Register (or replace, by identifier) one pending alert.
    func schedule(_ notification: CookTimerNotification)

    /// Remove any pending alerts with these identifiers. A no-op for ids that
    /// aren't currently scheduled.
    func cancelNotifications(identifiers: [String])
}
