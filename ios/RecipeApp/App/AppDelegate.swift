//
//  AppDelegate.swift
//  RecipeApp
//
//  Minimal UIKit app delegate, adopted by the SwiftUI `RecipeApp` only to own
//  the notification-center delegate. Cook Mode's step-timer alerts (slices 4–5)
//  are scheduled for the exact case where the app is in the FOREGROUND — you're
//  looking at the recipe while it cooks — and by default iOS suppresses a
//  notification whose app is frontmost. `UNUserNotificationCenterDelegate`'s
//  `willPresent` is what tells the system to show it anyway.
//
//  It only presents alerts; it never touches timer state (an expired timer stays
//  "Done" until the user resets it — see CookTimerNotificationScheduler).
//

import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// Show step-timer alerts even while the app is foregrounded (the usual Cook
    /// Mode case), with a banner, sound, and an entry in Notification Center.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }
}
