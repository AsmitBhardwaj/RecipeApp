//
//  PlanReminder.swift
//  RecipeKit
//
//  The "plan next week" nudge: a LOCAL notification (no backend) fired 6 days
//  after a plan was generated, at 6pm local. This file is the pure part — date
//  math, the request value, the OS seam, and the deep-link landing rule — so all
//  of it is unit-testable without touching `UNUserNotificationCenter`.
//

import Foundation

// MARK: - Request

public struct PlanReminderRequest: Codable, Equatable, Sendable {
    public var identifier: String
    public var userId: String
    /// First (or only) fire time. For a repeating request only the weekday + time
    /// of day matter to the OS; this is kept for display and change detection.
    public var fireDate: Date
    /// Pro: repeat on `weekday` at `hour:minute` every week while reminders are on.
    public var repeatsWeekly: Bool
    /// `Calendar` weekday of `fireDate` (1 = Sunday).
    public var weekday: Int
    public var hour: Int
    public var minute: Int
    public var title: String
    public var body: String

    /// `userInfo` payload; the app delegate routes taps on `type`.
    public var userInfo: [String: String] {
        ["type": PlanReminderDeepLink.notificationType, "userId": userId]
    }
}

// MARK: - OS seam

public enum PlanReminderAuthorization: Equatable, Sendable {
    case notDetermined, granted, denied
}

public protocol PlanReminderScheduling {
    func authorization() async -> PlanReminderAuthorization
    /// Shows the system prompt (only if not yet determined). True when granted.
    func requestAuthorization() async -> Bool
    /// Adds the request, replacing any pending one with the same identifier.
    func schedule(_ request: PlanReminderRequest) async
    func cancel(identifiers: [String]) async
    func cancelAll(withPrefix prefix: String) async
}

// MARK: - Policy

public enum PlanReminderPolicy {
    public static let daysAfterPlan = 6
    public static let hour = 18
    public static let title = "Your week's almost done"
    public static let body = "Plan next week in 2 minutes."
    public static let identifierPrefix = "plan-reminder."

    public static func identifier(userId: String) -> String { identifierPrefix + userId }

    /// 6 calendar days after the plan's day, at 6pm local. Calendar arithmetic (not
    /// `+ 6 * 86_400`) so a DST change in between still lands on 6pm wall time.
    public static func fireDate(planGeneratedAt: Date, calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: planGeneratedAt)
        let target = calendar.date(byAdding: .day, value: daysAfterPlan, to: day) ?? day
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: target) ?? target
    }

    /// The next 6pm strictly after `now`.
    public static func nextEvening(after now: Date, calendar: Calendar = .current) -> Date {
        calendar.nextDate(
            after: now, matching: DateComponents(hour: hour, minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(24 * 60 * 60)
    }

    /// The reminder to schedule, or nil when there is nothing to arm.
    ///
    /// - `allowLapsed`: the user just asked for a reminder (or a new plan was made)
    ///   and the 6-day mark has already passed → fire at the next 6pm instead. A
    ///   silent re-sync passes false so a fired one-shot is never re-armed.
    ///   Pro's weekly repeat is never "lapsed": the weekday/time just recur.
    public static func request(
        userId: String,
        planGeneratedAt: Date?,
        now: Date,
        isPro: Bool,
        allowLapsed: Bool,
        calendar: Calendar = .current
    ) -> PlanReminderRequest? {
        let due = fireDate(planGeneratedAt: planGeneratedAt ?? now, calendar: calendar)
        let fire: Date
        if due > now || isPro {
            fire = due
        } else if allowLapsed {
            fire = nextEvening(after: now, calendar: calendar)
        } else {
            return nil
        }
        return PlanReminderRequest(
            identifier: identifier(userId: userId), userId: userId, fireDate: fire,
            repeatsWeekly: isPro, weekday: calendar.component(.weekday, from: fire),
            hour: hour, minute: 0, title: title, body: body
        )
    }

    public static func weekdayName(of date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }
}

// MARK: - Deep link

public enum PlanReminderLanding: Equatable, Sendable {
    /// Free account that has used its free plan: the Pro teaser (same as New plan).
    case teaser
    /// Pro (or a non-free plan): highlight the New plan button briefly.
    case highlightNewPlan
    /// No plan on screen yet; setup handles itself.
    case none
}

public enum PlanReminderDeepLink {
    public static let notificationType = "plan_reminder"

    /// Mirrors `BudgetPlanModel.newPlan()`: a free plan on a non-Pro account opens
    /// the teaser; anything else just points at New plan.
    public static func landing(isPro: Bool, hasPlan: Bool, isFreePlan: Bool) -> PlanReminderLanding {
        guard hasPlan else { return .none }
        return (isFreePlan && !isPro) ? .teaser : .highlightNewPlan
    }

    /// The account id from a delivered notification's `userInfo`, when it is one of ours.
    public static func userId(fromUserInfo info: [AnyHashable: Any]) -> String? {
        guard info["type"] as? String == notificationType else { return nil }
        return info["userId"] as? String
    }
}

// MARK: - Persistence

/// Per-account reminder state (App Group defaults, one JSON blob).
public struct PlanReminderState: Codable, Equatable, Sendable {
    /// The user has reminders switched on (card "Remind me" or Account toggle).
    public var enabled = false
    /// The card's ✕ was tapped.
    public var cardDismissed = false
    public var planGeneratedAt: Date?
    /// What is currently armed with the OS, if anything.
    public var scheduled: PlanReminderRequest?

    public init() {}
}

public struct PlanReminderStore {
    private static let baseKey = "plan_reminder_v1"
    private let defaults: UserDefaults
    private let storageKey: String

    public init(suiteName: String = AppGroup.identifier, userScope: String?) {
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
        storageKey = scopedStorageKey(Self.baseKey, userScope)
    }

    public init(defaults: UserDefaults, userScope: String?) {
        self.defaults = defaults
        storageKey = scopedStorageKey(Self.baseKey, userScope)
    }

    public func load() -> PlanReminderState {
        guard let data = defaults.data(forKey: storageKey),
              let state = try? JSONDecoder().decode(PlanReminderState.self, from: data) else { return PlanReminderState() }
        return state
    }

    public func save(_ state: PlanReminderState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

// MARK: - Service

@MainActor
public final class PlanReminderService {
    public enum EnableResult: Equatable {
        case scheduled(PlanReminderRequest)
        case denied
    }

    public let userId: String
    private let scheduler: PlanReminderScheduling
    private let store: PlanReminderStore
    private let calendar: Calendar
    private let now: () -> Date
    private let isPro: () -> Bool

    public init(
        userId: String,
        scheduler: PlanReminderScheduling,
        store: PlanReminderStore,
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init,
        isPro: @escaping () -> Bool
    ) {
        self.userId = userId
        self.scheduler = scheduler
        self.store = store
        self.calendar = calendar
        self.now = now
        self.isPro = isPro
    }

    public var state: PlanReminderState { store.load() }
    public var cardDismissed: Bool { state.cardDismissed }

    /// A reminder is armed and will still fire (a fired free one-shot is not active).
    public var isActive: Bool {
        guard let scheduled = state.scheduled else { return false }
        return scheduled.repeatsWeekly || scheduled.fireDate > now()
    }

    public func authorization() async -> PlanReminderAuthorization { await scheduler.authorization() }

    public func dismissCard() {
        var s = state
        s.cardDismissed = true
        store.save(s)
    }

    /// A plan was just generated: remember when, and — if reminders are on —
    /// REPLACE the pending reminder so there is only ever one per user.
    public func planGenerated(at date: Date) async {
        var s = state
        s.planGeneratedAt = date
        store.save(s)
        guard s.enabled, await scheduler.authorization() == .granted else { return }
        await arm(allowLapsed: true)
    }

    /// Turn reminders on. Shows the system permission prompt only here, when the
    /// user asked for it.
    public func enable() async -> EnableResult {
        var auth = await scheduler.authorization()
        if auth == .notDetermined {
            _ = await scheduler.requestAuthorization()
            auth = await scheduler.authorization()
        }
        guard auth == .granted else { return .denied }
        var s = state
        s.enabled = true
        store.save(s)
        guard let request = await arm(allowLapsed: true) else { return .denied }
        return .scheduled(request)
    }

    /// Turn reminders off and cancel whatever is pending.
    public func disable() async {
        var s = state
        s.enabled = false
        s.scheduled = nil
        store.save(s)
        await scheduler.cancel(identifiers: [PlanReminderPolicy.identifier(userId: userId)])
    }

    /// Idempotent re-arm for foreground / sign-in / Pro-status changes: Pro turns
    /// the pending one into a weekly repeat, a free reminder that already fired is
    /// left alone.
    public func sync() async {
        let s = state
        guard s.enabled else { return }
        guard await scheduler.authorization() == .granted else { return }
        let desired = PlanReminderPolicy.request(
            userId: userId, planGeneratedAt: s.planGeneratedAt, now: now(),
            isPro: isPro(), allowLapsed: false, calendar: calendar
        )
        guard let desired else {
            // A one-shot armed for "the next 6pm" (plan already past day 6 when the
            // user asked) is still pending — leave it be.
            if let pending = s.scheduled, !pending.repeatsWeekly, pending.fireDate > now() { return }
            if s.scheduled != nil {
                await scheduler.cancel(identifiers: [PlanReminderPolicy.identifier(userId: userId)])
                var cleared = s
                cleared.scheduled = nil
                store.save(cleared)
            }
            return
        }
        if desired != s.scheduled { await replace(desired) }
    }

    /// Sign-out / account teardown: drop every pending plan reminder from this
    /// device (state stays, so signing back in re-arms via `sync`).
    public static func cancelAllPending(scheduler: PlanReminderScheduling) async {
        await scheduler.cancelAll(withPrefix: PlanReminderPolicy.identifierPrefix)
    }

    #if DEBUG
    /// DEBUG: fire the real notification (same content + payload) after `seconds`,
    /// under its own identifier so the one-pending invariant is untouched.
    public func scheduleDebug(in seconds: TimeInterval) async -> Bool {
        if await scheduler.authorization() == .notDetermined { _ = await scheduler.requestAuthorization() }
        guard await scheduler.authorization() == .granted else { return false }
        let fire = now().addingTimeInterval(seconds)
        await scheduler.schedule(PlanReminderRequest(
            identifier: PlanReminderPolicy.identifier(userId: userId) + ".debug", userId: userId,
            fireDate: fire, repeatsWeekly: false, weekday: calendar.component(.weekday, from: fire),
            hour: calendar.component(.hour, from: fire), minute: calendar.component(.minute, from: fire),
            title: PlanReminderPolicy.title, body: PlanReminderPolicy.body
        ))
        return true
    }
    #endif

    // MARK: Private

    @discardableResult
    private func arm(allowLapsed: Bool) async -> PlanReminderRequest? {
        let s = state
        guard let request = PlanReminderPolicy.request(
            userId: userId, planGeneratedAt: s.planGeneratedAt, now: now(),
            isPro: isPro(), allowLapsed: allowLapsed, calendar: calendar
        ) else { return nil }
        await replace(request)
        return request
    }

    private func replace(_ request: PlanReminderRequest) async {
        await scheduler.cancel(identifiers: [request.identifier])
        await scheduler.schedule(request)
        var s = state
        s.scheduled = request
        store.save(s)
    }
}
