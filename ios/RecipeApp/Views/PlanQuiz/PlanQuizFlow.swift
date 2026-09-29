//
//  PlanQuizFlow.swift
//  RecipeApp
//
//  Runs a `PlanQuizSession` through the quiz screens. Used three ways:
//    • onboarding      — People → Diet → Mood → Appliances → Store → Budget
//    • plan setup      — Mood → Appliances → Store → Budget (existing users, and
//                        "New plan"), progress scoped to those 4 steps
//    • edit            — one screen, opened from Account → Plan preferences
//  The flow owns no persistence: `onFinish` receives the finished draft.
//

import RecipeKit
import SwiftUI

@MainActor
final class PlanQuizModel: ObservableObject {
    @Published var session: PlanQuizSession

    init(session: PlanQuizSession) {
        self.session = session
    }
}

struct PlanQuizFlow: View {
    @ObservedObject var model: PlanQuizModel
    /// Back on the first screen: leave the flow (to the intro screen, or dismiss).
    let onExit: (() -> Void)?
    /// Continue on the last screen, with the finished draft.
    let onFinish: (CookingPreferences) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var session: PlanQuizSession { model.session }

    private var continueTitle: String {
        if case .edit = session.kind { return "Continue" }
        return session.step == .budget ? "Build my week" : "Continue"
    }

    var body: some View {
        ZStack {
            screen
        }
    }

    private var screen: some View {
        QuizScreen(
            title: session.step.title,
            subtitle: session.step.subtitle,
            progress: session.progress,
            stepLabel: "Step \(session.index + 1) of \(session.steps.count)",
            continueTitle: continueTitle,
            canContinue: session.canContinue,
            onBack: goBack,
            showsBack: !(session.index == 0 && onExit == nil),
            onContinue: goForward
        ) {
            content
        }
        .id(session.step)
        .transition(reduceMotion ? .opacity : .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        ))
    }

    @ViewBuilder private var content: some View {
        switch session.step {
        case .people: QuizPeopleContent(model: model)
        case .diet: QuizDietContent(model: model)
        case .mood: QuizMoodContent(model: model)
        case .appliances: QuizAppliancesContent(model: model)
        case .store: QuizStoreContent(model: model)
        case .budget: QuizBudgetContent(model: model)
        }
    }

    private func goBack() {
        var next = model.session
        guard next.back() else { onExit?(); return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) { model.session = next }
    }

    private func goForward() {
        guard session.canContinue else { return }
        var next = model.session
        if next.advance() {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) { model.session = next }
        } else if session.isLast {
            onFinish(session.draft)
        }
    }
}
