//
//  ActiveTimersBadge.swift
//  RecipeApp
//
//  The persistent, floating badge that keeps running timers in view from ANY
//  step within Cook Mode — so a timer started on step 3 is still glanceable (and
//  reachable) from step 7. It is scoped to Cook Mode only: it lives inside the
//  Cook Mode modal, never app-wide and never outside it.
//
//  Layout for 2+ concurrent timers: the SOONEST-to-finish one is shown expanded
//  with its live countdown, plus a "+N" chip for the rest. Tapping jumps to the
//  soonest timer's step. (Stage 1 keeps it to a single jump target; a full
//  multi-timer list is deferred.)
//
//  Only RUNNING, not-yet-expired timers reach here (see `activeTimers`), so the
//  badge naturally disappears when the last one is paused or finishes.
//

import SwiftUI
import RecipeKit

struct ActiveTimersBadge: View {
    /// Soonest-to-finish first; never empty when this view is shown.
    let timers: [CookTimer]
    let onTap: (_ stepNumber: Int) -> Void

    var body: some View {
        guard let soonest = timers.first else { return AnyView(EmptyView()) }
        let extra = timers.count - 1

        return AnyView(
            Button {
                onTap(soonest.stepNumber)
            } label: {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 10) {
                        Image(systemName: "timer")
                            .font(.subheadline.weight(.bold))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Step \(soonest.stepNumber)")
                                .font(.caption2.weight(.semibold))
                                .opacity(0.85)
                            Text(CookClock.mmss(soonest.remaining(asOf: context.date)))
                                .font(.system(.headline, design: .rounded).weight(.semibold))
                                .monospacedDigit()
                        }
                        if extra > 0 {
                            Text("+\(extra)")
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.white.opacity(0.25), in: Capsule())
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.accentColor, in: Capsule())
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                extra > 0
                    ? "\(timers.count) timers running. Soonest, step \(soonest.stepNumber). Tap to jump."
                    : "Timer running on step \(soonest.stepNumber). Tap to jump."
            )
        )
    }
}
