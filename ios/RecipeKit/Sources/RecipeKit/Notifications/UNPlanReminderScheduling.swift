//
//  UNPlanReminderScheduling.swift
//  RecipeKit
//
//  Production adapter for `PlanReminderScheduling`, backed by the real
//  `UNUserNotificationCenter`. Only constructed by the app (tests use a spy).
//

import Foundation
import UserNotifications

public struct UNPlanReminderScheduling: PlanReminderScheduling {
    private let center: UNUserNotificationCenter
    private let calendar: Calendar

    public init(center: UNUserNotificationCenter = .current(), calendar: Calendar = .current) {
        self.center = center
        self.calendar = calendar
    }

    public func authorization() async -> PlanReminderAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        default: return .granted   // authorized, provisional, ephemeral
        }
    }

    public func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    public func schedule(_ request: PlanReminderRequest) async {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        content.userInfo = request.userInfo

        let components: DateComponents
        if request.repeatsWeekly {
            components = DateComponents(hour: request.hour, minute: request.minute, weekday: request.weekday)
        } else {
            components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: request.fireDate)
        }
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: request.repeatsWeekly)
        // Same identifier replaces any pending copy.
        try? await center.add(UNNotificationRequest(identifier: request.identifier, content: content, trigger: trigger))
    }

    public func cancel(identifiers: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    public func cancelAll(withPrefix prefix: String) async {
        let ids = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}
