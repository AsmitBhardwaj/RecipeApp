import XCTest
@testable import RecipeKit

// MARK: - Spy

private final class SpyScheduler: PlanReminderScheduling {
    var status: PlanReminderAuthorization = .notDetermined
    var grantOnRequest = true
    private(set) var promptCount = 0
    private(set) var pending: [String: PlanReminderRequest] = [:]
    private(set) var scheduleCalls: [PlanReminderRequest] = []
    private(set) var cancelled: [String] = []

    func authorization() async -> PlanReminderAuthorization { status }
    func requestAuthorization() async -> Bool {
        promptCount += 1
        if status == .notDetermined { status = grantOnRequest ? .granted : .denied }
        return status == .granted
    }
    func schedule(_ request: PlanReminderRequest) async {
        scheduleCalls.append(request)
        pending[request.identifier] = request
    }
    func cancel(identifiers: [String]) async {
        cancelled += identifiers
        identifiers.forEach { pending[$0] = nil }
    }
    func cancelAll(withPrefix prefix: String) async {
        for id in pending.keys where id.hasPrefix(prefix) { pending[id] = nil }
    }
}

// MARK: - Helpers

private func calendar(_ zone: String = "America/New_York") -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: zone)!
    return c
}

private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, cal: Calendar) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

// MARK: - Date math

final class PlanReminderDateMathTests: XCTestCase {

    func testSixDaysLaterAtSixPMLocal() {
        let cal = calendar()
        let fire = PlanReminderPolicy.fireDate(planGeneratedAt: date(2026, 9, 29, 9, 30, cal: cal), calendar: cal)
        XCTAssertEqual(fire, date(2026, 10, 5, 18, 0, cal: cal))
    }

    func testTimeOfDayOfGenerationDoesNotMatter() {
        let cal = calendar()
        let early = PlanReminderPolicy.fireDate(planGeneratedAt: date(2026, 9, 29, 0, 5, cal: cal), calendar: cal)
        let late = PlanReminderPolicy.fireDate(planGeneratedAt: date(2026, 9, 29, 23, 55, cal: cal), calendar: cal)
        XCTAssertEqual(early, late)
    }

    func testStaysAtSixPMWhenClocksFallBack() {
        // DST ends Sun 1 Nov 2026 (US): Fri 30 Oct → Thu 5 Nov crosses it.
        let cal = calendar()
        let fire = PlanReminderPolicy.fireDate(planGeneratedAt: date(2026, 10, 30, 14, 0, cal: cal), calendar: cal)
        XCTAssertEqual(fire, date(2026, 11, 5, 18, 0, cal: cal))
        XCTAssertEqual(cal.component(.hour, from: fire), 18)
        // Wall-clock 6 days later is 6 days + 1 hour of real time.
        XCTAssertEqual(fire.timeIntervalSince(date(2026, 10, 30, 18, 0, cal: cal)), 6 * 86_400 + 3_600)
    }

    func testStaysAtSixPMWhenClocksSpringForward() {
        // DST starts Sun 8 Mar 2026: Thu 5 Mar → Wed 11 Mar crosses it.
        let cal = calendar()
        let fire = PlanReminderPolicy.fireDate(planGeneratedAt: date(2026, 3, 5, 10, 0, cal: cal), calendar: cal)
        XCTAssertEqual(fire, date(2026, 3, 11, 18, 0, cal: cal))
        XCTAssertEqual(cal.component(.hour, from: fire), 18)
        XCTAssertEqual(fire.timeIntervalSince(date(2026, 3, 5, 18, 0, cal: cal)), 6 * 86_400 - 3_600)
    }

    func testMonthAndYearRollover() {
        let cal = calendar()
        XCTAssertEqual(PlanReminderPolicy.fireDate(planGeneratedAt: date(2026, 12, 28, 12, cal: cal), calendar: cal),
                       date(2027, 1, 3, 18, cal: cal))
    }

    func testLapsedFreeReminderNeedsExplicitPermissionToFireAtNextEvening() {
        let cal = calendar()
        let generated = date(2026, 9, 1, 12, cal: cal)
        let now = date(2026, 9, 20, 10, cal: cal)
        XCTAssertNil(PlanReminderPolicy.request(userId: "u", planGeneratedAt: generated, now: now, isPro: false,
                                                allowLapsed: false, calendar: cal))
        let asked = PlanReminderPolicy.request(userId: "u", planGeneratedAt: generated, now: now, isPro: false,
                                               allowLapsed: true, calendar: cal)
        XCTAssertEqual(asked?.fireDate, date(2026, 9, 20, 18, cal: cal))
        let lateNow = date(2026, 9, 20, 19, cal: cal)
        XCTAssertEqual(PlanReminderPolicy.request(userId: "u", planGeneratedAt: generated, now: lateNow, isPro: false,
                                                  allowLapsed: true, calendar: cal)?.fireDate,
                       date(2026, 9, 21, 18, cal: cal))
    }

    func testRequestCarriesContentWeekdayAndPayload() throws {
        let cal = calendar()
        let request = try XCTUnwrap(PlanReminderPolicy.request(
            userId: "u1", planGeneratedAt: date(2026, 9, 29, 9, cal: cal), now: date(2026, 9, 29, 9, cal: cal),
            isPro: false, allowLapsed: true, calendar: cal))
        XCTAssertEqual(request.title, "Your week's almost done")
        XCTAssertEqual(request.body, "Plan next week in 2 minutes.")
        XCTAssertEqual(request.weekday, 2)   // Monday 5 Oct 2026
        XCTAssertEqual(request.hour, 18)
        XCTAssertEqual(request.userInfo["type"], "plan_reminder")
        XCTAssertEqual(PlanReminderPolicy.weekdayName(of: request.fireDate, calendar: cal, locale: Locale(identifier: "en_US")), "Monday")
    }
}

// MARK: - Service

@MainActor
final class PlanReminderServiceTests: XCTestCase {
    private let cal = calendar()
    private var spy = SpyScheduler()
    private var pro = false
    private var clock = Date()
    private var defaults = UserDefaults(suiteName: "rem-\(UUID().uuidString)")!

    override func setUp() {
        super.setUp()
        spy = SpyScheduler()
        pro = false
        clock = date(2026, 9, 29, 9, cal: cal)
        defaults = UserDefaults(suiteName: "rem-\(UUID().uuidString)")!
    }

    private func service(user: String = "u1") -> PlanReminderService {
        PlanReminderService(
            userId: user, scheduler: spy, store: PlanReminderStore(defaults: defaults, userScope: user),
            calendar: cal, now: { self.clock }, isPro: { self.pro }
        )
    }

    func testEnableRequestsPermissionOnlyWhenAskedAndSchedulesOnGrant() async {
        let s = service()
        await s.planGenerated(at: clock)
        XCTAssertEqual(spy.promptCount, 0, "generating a plan must never prompt")
        let result = await s.enable()
        XCTAssertEqual(spy.promptCount, 1)
        guard case .scheduled(let request) = result else { return XCTFail("expected scheduled, got \(result)") }
        XCTAssertEqual(request.fireDate, date(2026, 10, 5, 18, cal: cal))
        XCTAssertEqual(spy.pending.count, 1)
        XCTAssertTrue(s.isActive)
    }

    func testDeniedPermissionSchedulesNothing() async {
        spy.grantOnRequest = false
        let s = service()
        await s.planGenerated(at: clock)
        let result = await s.enable()
        XCTAssertEqual(result, .denied)
        XCTAssertTrue(spy.pending.isEmpty)
        XCTAssertFalse(s.isActive)
        let auth = await s.authorization()
        XCTAssertEqual(auth, .denied)
    }

    func testAlreadyDeniedDoesNotPromptAgain() async {
        spy.status = .denied
        let result = await service().enable()
        XCTAssertEqual(result, .denied)
        XCTAssertEqual(spy.promptCount, 0)
    }

    func testNewPlanReplacesThePendingReminder() async {
        let s = service()
        await s.planGenerated(at: clock)
        _ = await s.enable()
        let first = spy.pending["plan-reminder.u1"]
        clock = date(2026, 10, 2, 9, cal: cal)
        await s.planGenerated(at: clock)
        XCTAssertEqual(spy.pending.count, 1, "one pending reminder per user")
        XCTAssertNotEqual(spy.pending["plan-reminder.u1"]?.fireDate, first?.fireDate)
        XCTAssertEqual(spy.pending["plan-reminder.u1"]?.fireDate, date(2026, 10, 8, 18, cal: cal))
        XCTAssertEqual(s.state.scheduled?.fireDate, date(2026, 10, 8, 18, cal: cal))
    }

    func testNewPlanDoesNotScheduleWhenRemindersAreOff() async {
        spy.status = .granted
        let s = service()
        await s.planGenerated(at: clock)
        XCTAssertTrue(spy.pending.isEmpty)
        XCTAssertNotNil(s.state.planGeneratedAt)
    }

    func testProRepeatsWeeklyOnThatWeekdayAt6PM() async throws {
        pro = true
        let s = service()
        await s.planGenerated(at: clock)
        _ = await s.enable()
        let request = try XCTUnwrap(spy.pending["plan-reminder.u1"])
        XCTAssertTrue(request.repeatsWeekly)
        XCTAssertEqual(request.weekday, 2)
        XCTAssertEqual(request.hour, 18)
        XCTAssertEqual(request.minute, 0)
    }

    func testFreeReminderDoesNotRepeat() async throws {
        let s = service()
        await s.planGenerated(at: clock)
        _ = await s.enable()
        XCTAssertFalse(try XCTUnwrap(spy.pending["plan-reminder.u1"]).repeatsWeekly)
    }

    func testUpgradingToProTurnsPendingReminderIntoWeeklyRepeat() async throws {
        let s = service()
        await s.planGenerated(at: clock)
        _ = await s.enable()
        pro = true
        await s.sync()
        XCTAssertEqual(spy.pending.count, 1)
        XCTAssertTrue(try XCTUnwrap(spy.pending["plan-reminder.u1"]).repeatsWeekly)
    }

    func testProRepeatSurvivesPastTheFirstFireDate() async throws {
        pro = true
        let s = service()
        await s.planGenerated(at: clock)
        _ = await s.enable()
        clock = date(2026, 10, 20, 9, cal: cal)   // weeks later
        await s.sync()
        XCTAssertTrue(s.isActive)
        XCTAssertTrue(try XCTUnwrap(spy.pending["plan-reminder.u1"]).repeatsWeekly)
    }

    func testFiredFreeReminderIsNotReArmedBySync() async {
        let s = service()
        await s.planGenerated(at: clock)
        _ = await s.enable()
        clock = date(2026, 10, 5, 19, cal: cal)   // it fired at 18:00
        let callsBefore = spy.scheduleCalls.count
        await s.sync()
        XCTAssertEqual(spy.scheduleCalls.count, callsBefore)
        XCTAssertFalse(s.isActive)
        XCTAssertNil(s.state.scheduled)
    }

    func testEnablingOnAnOldPlanArmsTheNextEveningAndSyncKeepsIt() async {
        let s = service()
        await s.planGenerated(at: date(2026, 9, 1, 9, cal: cal))
        let result = await s.enable()
        guard case .scheduled(let request) = result else { return XCTFail("expected scheduled") }
        XCTAssertEqual(request.fireDate, date(2026, 9, 29, 18, cal: cal))
        await s.sync()
        XCTAssertEqual(spy.pending.count, 1)
        XCTAssertTrue(s.isActive)
    }

    func testTurningRemindersOffCancelsPendingAndFlipsState() async {
        let s = service()
        await s.planGenerated(at: clock)
        _ = await s.enable()
        XCTAssertEqual(spy.pending.count, 1)
        await s.disable()
        XCTAssertTrue(spy.pending.isEmpty)
        XCTAssertFalse(s.isActive)
        XCTAssertFalse(s.state.enabled)
        // A later plan must not silently re-arm it.
        await s.planGenerated(at: clock)
        XCTAssertTrue(spy.pending.isEmpty)
    }

    func testRemindersArePerUser() async {
        let a = service(user: "a"), b = service(user: "b")
        await a.planGenerated(at: clock)
        _ = await a.enable()
        XCTAssertFalse(b.isActive)
        XCTAssertEqual(Set(spy.pending.keys), ["plan-reminder.a"])
    }

    func testCardDismissalPersistsPerUser() {
        service().dismissCard()
        XCTAssertTrue(service().cardDismissed)
        XCTAssertFalse(service(user: "u2").cardDismissed)
    }

    func testSignOutCancelsEveryPendingReminderButKeepsTheSetting() async {
        let s = service()
        await s.planGenerated(at: clock)
        _ = await s.enable()
        await PlanReminderService.cancelAllPending(scheduler: spy)
        XCTAssertTrue(spy.pending.isEmpty)
        XCTAssertTrue(s.state.enabled)
        // Signing back in re-arms it.
        await s.planGenerated(at: clock)
        XCTAssertEqual(spy.pending.count, 1)
    }

    func testDebugReminderFiresInTenSecondsUnderItsOwnIdentifier() async throws {
        let s = service()
        await s.planGenerated(at: clock)
        _ = await s.enable()
        let ok = await s.scheduleDebug(in: 10)
        XCTAssertTrue(ok)
        XCTAssertEqual(spy.pending.count, 2)
        let debug = try XCTUnwrap(spy.pending["plan-reminder.u1.debug"])
        XCTAssertEqual(debug.fireDate, clock.addingTimeInterval(10))
        XCTAssertEqual(debug.userInfo["type"], "plan_reminder")
        XCTAssertNotNil(spy.pending["plan-reminder.u1"])
    }
}

// MARK: - Deep link

final class PlanReminderDeepLinkTests: XCTestCase {
    func testFreeUserWithUsedFreePlanGetsTheTeaser() {
        XCTAssertEqual(PlanReminderDeepLink.landing(isPro: false, hasPlan: true, isFreePlan: true), .teaser)
    }

    func testProUserGetsNewPlanHighlight() {
        XCTAssertEqual(PlanReminderDeepLink.landing(isPro: true, hasPlan: true, isFreePlan: false), .highlightNewPlan)
        XCTAssertEqual(PlanReminderDeepLink.landing(isPro: true, hasPlan: true, isFreePlan: true), .highlightNewPlan)
    }

    func testNoPlanLetsSetupHandleItself() {
        XCTAssertEqual(PlanReminderDeepLink.landing(isPro: false, hasPlan: false, isFreePlan: false), .none)
        XCTAssertEqual(PlanReminderDeepLink.landing(isPro: true, hasPlan: false, isFreePlan: false), .none)
    }

    func testUserIdParsingOnlyAcceptsPlanReminders() {
        XCTAssertEqual(PlanReminderDeepLink.userId(fromUserInfo: ["type": "plan_reminder", "userId": "u1"]), "u1")
        XCTAssertNil(PlanReminderDeepLink.userId(fromUserInfo: ["type": "cook_timer", "userId": "u1"]))
        XCTAssertNil(PlanReminderDeepLink.userId(fromUserInfo: [:]))
    }
}
