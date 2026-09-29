//
//  PlanLoadingView.swift
//  RecipeApp
//
//  "Building your week…" — the loading screen for plan generation (onboarding and
//  every later plan). The user's own quiz answers appear one after another, each
//  with a sage check; the last line ("Fitting it into $75") spins until the API
//  responds. The screen holds for at least `PlanLoadingTiming.minimumDuration`
//  (enforced by `BudgetPlanModel`, which only leaves `.generating` after that).
//

import SwiftUI
import RecipeKit

struct PlanLoadingView: View {
    @ObservedObject var model: BudgetPlanModel
    let prefs: CookingPreferences

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How many rows (answer lines, then the final line) have appeared.
    @State private var visibleCount = 0
    @State private var progress: Double = 0

    private var answerLines: [String] { PlanLoadingScript.answerLines(for: prefs) }
    private var finalLine: String { PlanLoadingScript.finalLine(budget: prefs.weeklyBudget ?? Int(model.budgetValue.rounded())) }
    private var rowCount: Int { answerLines.count + 1 }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 16)
            SoftAssetImage(name: "sticker_hero", size: 140, cornerRadius: 28)
            Text("Building your week…")
                .font(.editorialTitle(size: 32, relativeTo: .largeTitle))
                .foregroundStyle(Color.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.top, 20)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(answerLines.enumerated()), id: \.offset) { index, line in
                    row(line, index: index, isFinal: false)
                }
                row(finalLine, index: answerLines.count, isFinal: true)
            }
            .padding(.top, 28)
            Spacer(minLength: 16)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) { progressBar }
        .task { await playLines() }
        .onAppear {
            if reduceMotion {
                progress = PlanLoadingTiming.waitingProgress
            } else {
                withAnimation(.easeOut(duration: 8)) { progress = PlanLoadingTiming.waitingProgress }
            }
        }
        .onChange(of: model.loadingResponseArrived) { _, arrived in
            if arrived { withAnimation(.easeOut(duration: 0.3)) { progress = 1 } }
        }
    }

    // MARK: Rows

    private func row(_ text: String, index: Int, isFinal: Bool) -> some View {
        let visible = index < visibleCount
        let spinning = isFinal && !model.loadingResponseArrived
        return HStack(spacing: 12) {
            if spinning {
                SpinningRing(reduceMotion: reduceMotion)
            } else {
                CheckCircle()
            }
            Text(text)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .opacity(visible ? 1 : 0)
        .offset(y: visible || reduceMotion ? 0 : 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spinning ? "\(text), in progress" : text)
        .accessibilityHidden(!visible)
    }

    /// Rows appear ~0.7s apart, each fading and sliding up 10pt with a spring.
    /// Reduce Motion: all at once, no slide.
    private func playLines() async {
        guard !reduceMotion else {
            visibleCount = rowCount
            return
        }
        try? await Task.sleep(nanoseconds: 350_000_000)
        for _ in 0..<rowCount {
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { visibleCount += 1 }
            try? await Task.sleep(nanoseconds: UInt64(PlanLoadingTiming.lineInterval * 1_000_000_000))
        }
    }

    // MARK: Progress bar

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.planSelectedTint)
                Capsule().fill(Color.accentColor).frame(width: geo.size.width * progress)
            }
        }
        .frame(height: 4)
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .accessibilityHidden(true)
    }
}

/// The sage check circle beside each answer.
private struct CheckCircle: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(Color.accentColor, in: Circle())
            .accessibilityHidden(true)
    }
}

/// The last line's indicator: a sage ring spinning until the response lands.
/// (Reduce Motion falls back to the system spinner.)
private struct SpinningRing: View {
    let reduceMotion: Bool
    @State private var spinning = false

    var body: some View {
        Group {
            if reduceMotion {
                ProgressView().tint(Color.accentColor)
            } else {
                Circle()
                    .trim(from: 0, to: 0.72)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                    .onAppear {
                        withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spinning = true }
                    }
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}
