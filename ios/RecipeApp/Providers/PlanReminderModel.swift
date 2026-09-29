//
//  PlanReminderModel.swift
//  RecipeApp
//
//  Observable wrapper over `PlanReminderService` (the day-6 "plan next week"
//  local notification) for the "Your week" card and the Account toggle, plus the
//  router that carries a notification tap to Meal Plan → Plan on a Budget.
//

import Foundation
import RecipeKit
import UIKit

@MainActor
final class PlanReminderModel: ObservableObject {
    enum CardState: Equatable {
        case hidden
        case offer
        case confirmed(weekday: String)
        case needsSettings
    }

    @Published private(set) var cardState: CardState = .hidden
    /// A reminder is armed and will fire — drives the Account toggle.
    @Published private(set) var isOn = false
    /// The OS switched notifications off for Platter (Account toggle can't turn on).
    @Published private(set) var isDenied = false

    private let service: PlanReminderService
    private var confirmedWeekday: String?

    init(userId: String, isPro: @escaping () -> Bool, scheduler: PlanReminderScheduling = UNPlanReminderScheduling()) {
        service = PlanReminderService(
            userId: userId, scheduler: scheduler,
            store: PlanReminderStore(userScope: userId), isPro: isPro
        )
        Task { await refresh() }
    }

    /// Re-read the OS + stored state; re-arms after a Pro change / sign-in. Called
    /// on launch, foreground, and when Pro status flips. Never prompts.
    func refresh() async {
        await service.sync()
        let auth = await service.authorization()
        isDenied = auth == .denied
        isOn = service.isActive && auth == .granted
        if let confirmedWeekday {
            cardState = .confirmed(weekday: confirmedWeekday)
        } else if service.cardDismissed || isOn {
            cardState = .hidden
        } else {
            cardState = isDenied ? .needsSettings : .offer
        }
    }

    /// A new plan was generated: remember it and replace the pending reminder.
    func planGenerated(at date: Date = Date()) {
        Task {
            await service.planGenerated(at: date)
            confirmedWeekday = nil
            await refresh()
        }
    }

    /// "Remind me" — the only place (with the Account toggle) that prompts.
    func remindMe() {
        Task {
            switch await service.enable() {
            case .scheduled(let request):
                confirmedWeekday = PlanReminderPolicy.weekdayName(of: request.fireDate)
            case .denied:
                confirmedWeekday = nil
            }
            await refresh()
        }
    }

    func dismissCard() {
        service.dismissCard()
        confirmedWeekday = nil
        Task { await refresh() }
    }

    /// Account toggle.
    func setEnabled(_ on: Bool) {
        Task {
            if on {
                if case .denied = await service.enable() { confirmedWeekday = nil }
            } else {
                await service.disable()
                confirmedWeekday = nil
            }
            await refresh()
        }
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Sign-out: nothing should fire for a signed-out device.
    static func cancelAllPending() {
        Task { await PlanReminderService.cancelAllPending(scheduler: UNPlanReminderScheduling()) }
    }

    #if DEBUG
    /// Account → Developer: fire the real reminder in 10 seconds (prompts if needed).
    func scheduleDebugReminder() {
        Task { _ = await service.scheduleDebug(in: 10); await refresh() }
    }
    #endif
}

/// Carries a tapped plan-reminder notification to the UI. `pendingUserId` is held
/// until Meal Plan → Plan on a Budget consumes it (so a cold launch through
/// splash / sign-in still lands correctly).
@MainActor
final class PlanReminderRouter: ObservableObject {
    static let shared = PlanReminderRouter()
    @Published private(set) var pendingUserId: String?

    func open(userId: String) { pendingUserId = userId }

    func isPending(for userId: String?) -> Bool { userId != nil && pendingUserId == userId }

    func consume() { pendingUserId = nil }
}
