//
//  CookTimerSchedulerEnvironment.swift
//  RecipeApp
//
//  Passes the app-wide `CookTimerNotificationScheduler` down to wherever Cook
//  Mode is launched (Recipe Detail) without threading it through every
//  intervening view. The default builds a real UNUserNotificationCenter-backed
//  scheduler, so previews and any un-injected call site still function.
//

import SwiftUI
import RecipeKit

private struct CookTimerSchedulerKey: EnvironmentKey {
    static let defaultValue = CookTimerNotificationScheduler(
        center: UNCookTimerNotificationScheduling()
    )
}

extension EnvironmentValues {
    var cookTimerScheduler: CookTimerNotificationScheduler {
        get { self[CookTimerSchedulerKey.self] }
        set { self[CookTimerSchedulerKey.self] = newValue }
    }
}
