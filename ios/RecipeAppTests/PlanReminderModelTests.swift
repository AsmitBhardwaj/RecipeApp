//
//  PlanReminderModelTests.swift
//  RecipeAppTests
//
//  Stage 4: the Account toggle cancelling pending reminders, a new plan replacing
//  the pending one, and the notification-tap landing for free vs Pro on "Your week".
//

import XCTest
@testable import RecipeApp
import RecipeKit

private final class SpyReminderScheduler: PlanReminderScheduling {
    var status: PlanReminderAuthorization = .granted
    private(set) var pending: [String: PlanReminderRequest] = [:]
    func authorization() async -> PlanReminderAuthorization { status }
    func requestAuthorization() async -> Bool { status == .granted }
    func schedule(_ request: PlanReminderRequest) async { pending[request.identifier] = request }
    func cancel(identifiers: [String]) async { identifiers.forEach { pending[$0] = nil } }
    func cancelAll(withPrefix prefix: String) async { for k in pending.keys where k.hasPrefix(prefix) { pending[k] = nil } }
}

@MainActor
final class PlanReminderModelTests: XCTestCase {

    private func eventually(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), what)
    }

    func testSettingsToggleOffCancelsPendingReminderAndOnRestoresIt() async {
        let spy = SpyReminderScheduler()
        let model = PlanReminderModel(userId: "toggle-\(UUID().uuidString)", isPro: { false }, scheduler: spy)
        model.planGenerated(at: Date())
        model.setEnabled(true)
        await eventually("reminder armed") { model.isOn && spy.pending.count == 1 }

        model.setEnabled(false)
        await eventually("reminder cancelled") { !model.isOn && spy.pending.isEmpty }

        model.setEnabled(true)
        await eventually("re-armed") { model.isOn && spy.pending.count == 1 }
    }

    func testNewPlanReplacesPendingReminderWithoutDuplicating() async {
        let spy = SpyReminderScheduler()
        let model = PlanReminderModel(userId: "replace-\(UUID().uuidString)", isPro: { false }, scheduler: spy)
        let first = Date()
        model.planGenerated(at: first)
        model.setEnabled(true)
        await eventually("armed") { spy.pending.count == 1 }
        let firstFire = spy.pending.values.first?.fireDate

        model.planGenerated(at: first.addingTimeInterval(3 * 86_400))
        await eventually("replaced") { spy.pending.values.first?.fireDate != firstFire }
        XCTAssertEqual(spy.pending.count, 1)
    }

    func testDeniedPermissionShowsSettingsCardAndSchedulesNothing() async {
        let spy = SpyReminderScheduler()
        spy.status = .denied
        let model = PlanReminderModel(userId: "denied-\(UUID().uuidString)", isPro: { false }, scheduler: spy)
        await eventually("needs settings") { model.cardState == .needsSettings }
        model.remindMe()
        await eventually("still needs settings") { model.isDenied }
        XCTAssertEqual(model.cardState, .needsSettings)
        XCTAssertTrue(spy.pending.isEmpty)
    }

    func testRemindMeShowsConfirmationThenDismissPersists() async {
        let spy = SpyReminderScheduler()
        let user = "card-\(UUID().uuidString)"
        let model = PlanReminderModel(userId: user, isPro: { false }, scheduler: spy)
        await eventually("offer") { model.cardState == .offer }
        model.remindMe()
        await eventually("confirmed") { if case .confirmed = model.cardState { return true } else { return false } }
        // A fresh model (next launch) hides the card: a reminder is already scheduled.
        let relaunched = PlanReminderModel(userId: user, isPro: { false }, scheduler: spy)
        await eventually("hidden when scheduled") { relaunched.cardState == .hidden && relaunched.isOn }
    }

    // MARK: Deep-link landing on "Your week"

    private func planned(_ id: String) -> PlannedRecipe {
        let recipe = Recipe(
            recipeId: id, canonicalVideoId: "budget:\(id)", title: "Meal \(id)",
            servings: Servings(amount: 2, unit: nil), prepTimeMinutes: nil, cookTimeMinutes: nil,
            totalTimeMinutes: nil, ingredients: [], instructions: [], confidence: nil,
            sourceType: .generated, imageUrl: nil, imageSource: .none, transcript: nil
        )
        return PlannedRecipe(recipe: recipe, estimatedCost: CostEstimate(amount: 10), healthSignal: "")
    }

    private func modelWithPlan(isPro: Bool, isFree: Bool, generated: @escaping (Date) -> Void = { _ in }) async -> BudgetPlanModel {
        let response = BudgetPlanResponse(
            recipes: (1...5).map { planned("m\($0)") }, currency: "USD", budget: 75, minBudget: 50,
            regionalMultiplier: 1, planId: "p", isFree: isFree, swapsRemaining: isFree ? 3 : nil
        )
        let model = BudgetPlanModel(
            householdSize: 2, dietaryPreferences: [], pantryNames: { [] },
            generate: { _, _, _, _, _ in response },
            swap: { _, _ in throw BudgetPlanError.http(500) }, commit: { _ in },
            onPlanGenerated: generated, isPro: { isPro }, sleep: { _ in }
        )
        await model.generatePlan()
        return model
    }

    func testTapOnFreeUsedPlanOpensTheTeaser() async {
        let model = await modelWithPlan(isPro: false, isFree: true)
        XCTAssertFalse(model.showTeaser)
        model.handleReminderOpen()
        XCTAssertTrue(model.showTeaser)
        XCTAssertFalse(model.highlightNewPlan)
    }

    func testTapForProHighlightsNewPlanWithoutTeaser() async {
        let model = await modelWithPlan(isPro: true, isFree: false)
        model.handleReminderOpen()
        XCTAssertTrue(model.highlightNewPlan)
        XCTAssertFalse(model.showTeaser)
        await Task.yield()
        for _ in 0..<50 where model.highlightNewPlan { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.highlightNewPlan, "highlight is brief")
    }

    func testTapWithNoPlanDoesNothing() {
        let model = BudgetPlanModel(
            householdSize: 2, dietaryPreferences: [], pantryNames: { [] },
            generate: { _, _, _, _, _ in throw BudgetPlanError.http(500) },
            swap: { _, _ in throw BudgetPlanError.http(500) }, commit: { _ in }
        )
        model.handleReminderOpen()
        XCTAssertFalse(model.showTeaser)
        XCTAssertFalse(model.highlightNewPlan)
    }

    func testGeneratingAPlanReportsItsGenerationTime() async {
        var reported: Date?
        _ = await modelWithPlan(isPro: false, isFree: true) { reported = $0 }
        XCTAssertNotNil(reported)
    }
}
