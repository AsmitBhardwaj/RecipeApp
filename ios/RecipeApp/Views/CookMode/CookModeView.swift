//
//  CookModeView.swift
//  RecipeApp
//
//  The full-screen, guided Cook Mode: one step per screen, with a per-step timer
//  where the step has a duration. Presented as a full-screen cover (NOT a
//  dismissible sheet) so a stray swipe can't drop the user out mid-cook.
//
//  Visual language is the app's existing sage/cream/clay-brown palette and DM
//  Serif Display for the step text — no new look for this screen.
//
//  While Cook Mode is foregrounded the idle timer is disabled so the screen
//  never sleeps mid-recipe; it is restored on exit. Exiting (X) does NOT stop
//  running timers — they keep counting and still fire their notifications; the
//  next entry reads them back correctly counted-down.
//

import SwiftUI
import RecipeKit

struct CookModeView: View {
    @StateObject private var model: CookModeModel
    @Environment(\.dismiss) private var dismiss

    init(recipe: Recipe, userScope: String?, scheduler: CookTimerNotificationScheduler) {
        _model = StateObject(wrappedValue: CookModeModel(
            recipe: recipe, userScope: userScope, scheduler: scheduler
        ))
    }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                progressIndicator
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                stepPager
                navigationControls
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }

            // Persistent within Cook Mode, above the step content, reachable from
            // any step.
            badgeOverlay
        }
        .foregroundStyle(Color.textPrimary)
        // Keep the screen awake for the length of the cook; restore on exit.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    // MARK: - Top bar (title + close)

    private var topBar: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(model.recipe.title)
                .font(.editorialTitle(size: 20, relativeTo: .title3))
                .lineLimit(1)
            Spacer(minLength: 12)
            Button {
                dismiss() // running timers keep running; they're in the store.
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.bold))
                    .foregroundStyle(Color.textSecondary)
                    .frame(width: 40, height: 40)
                    .background(Color.textSecondary.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Exit Cook Mode")
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    // MARK: - Segmented progress ("Step 4 of 9")

    private var progressIndicator: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Step \(model.currentIndex + 1) of \(model.stepCount)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.textSecondary)
            HStack(spacing: 4) {
                ForEach(0..<max(model.stepCount, 1), id: \.self) { i in
                    Capsule()
                        .fill(i <= model.currentIndex ? Color.accentColor : Color.cardEdge.opacity(0.5))
                        .frame(height: 5)
                }
            }
        }
    }

    // MARK: - Step content (one per screen, swipeable)

    private var stepPager: some View {
        TabView(selection: Binding(
            get: { model.currentIndex },
            set: { model.goToStep(index: $0) }
        )) {
            ForEach(Array(model.steps.enumerated()), id: \.offset) { index, step in
                stepScreen(step)
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    private func stepScreen(_ step: Instruction) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text(step.text)
                    .font(.editorialTitle(size: 30, relativeTo: .title))
                    .lineSpacing(6)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Timer card ONLY when this step actually has a duration.
                if let duration = step.effectiveDurationSeconds {
                    CookStepTimerCard(
                        step: step,
                        duration: duration,
                        timer: model.timer(for: step),
                        onPlayPause: { model.togglePlayPause(for: step) },
                        onReset: { model.reset(step: step) }
                    )
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 120) // clear the badge / nav controls
        }
    }

    // MARK: - Back / Next (independent of timer state)

    private var navigationControls: some View {
        HStack(spacing: 14) {
            navButton(title: "Back", system: "chevron.left", enabled: model.canGoBack) {
                model.goBack()
            }
            navButton(title: "Next", system: "chevron.right", trailingIcon: true, enabled: model.canGoNext) {
                model.goNext()
            }
        }
    }

    private func navButton(
        title: String,
        system: String,
        trailingIcon: Bool = false,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if !trailingIcon { Image(systemName: system) }
                Text(title)
                if trailingIcon { Image(systemName: system) }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .foregroundStyle(enabled ? .white : Color.textSecondary)
            .background(
                enabled ? Color.accentColor : Color.textSecondary.opacity(0.15),
                in: RoundedRectangle(cornerRadius: 14)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: - Active-timer badge

    private var badgeOverlay: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let active = model.activeTimers(asOf: context.date)
            VStack {
                Spacer()
                if !active.isEmpty {
                    ActiveTimersBadge(timers: active) { stepNumber in
                        withAnimation(.easeInOut) { model.goToStep(number: stepNumber) }
                    }
                    // Float just above the Back/Next row.
                    .padding(.bottom, 76)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: active.count)
            .allowsHitTesting(!active.isEmpty)
        }
    }
}
