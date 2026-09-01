//
//  CookStepTimerCard.swift
//  RecipeApp
//
//  The timer for one Cook Mode step. Rendered ONLY on steps that have a duration
//  (`Instruction.effectiveDurationSeconds`) — steps without one show no timer UI
//  at all (the parent guards on that).
//
//  Countdown ticks via a `TimelineView`: the `CookTimer` state is stored, but
//  remaining time is derived from the wall clock each second, so this stays
//  correct across backgrounding and re-entry with no running in-app clock. On
//  expiry it holds at "0:00 · Done" until the user resets — it never auto-clears
//  and never mutates state on its own.
//

import SwiftUI
import RecipeKit

struct CookStepTimerCard: View {
    let step: Instruction
    let duration: Int
    /// The persisted timer for this step, if one has been started (nil = idle).
    let timer: CookTimer?

    let onPlayPause: () -> Void
    let onReset: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let remaining = timer?.remaining(asOf: now) ?? Double(duration)
            let expired = timer?.isExpired(asOf: now) ?? false
            let running = timer?.isRunning ?? false

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(CookClock.mmss(remaining))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(expired ? Color.accentColor : Color.textPrimary)
                    Text(statusLabel(expired: expired, running: running))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.textSecondary)
                }

                Spacer(minLength: 0)

                // Reset appears once a timer exists (running, paused, or done).
                if timer != nil {
                    controlButton(
                        system: "arrow.counterclockwise",
                        filled: false,
                        action: onReset
                    )
                    .accessibilityLabel("Reset timer")
                }

                // Primary play/pause. Disabled once expired — only Reset acts then.
                controlButton(
                    system: expired ? "checkmark" : (running ? "pause.fill" : "play.fill"),
                    filled: true,
                    action: onPlayPause
                )
                .disabled(expired)
                .accessibilityLabel(running ? "Pause timer" : "Start timer")
            }
            .padding(.vertical, 4)
        }
        .tornEdgeCard(padding: 18)
    }

    private func statusLabel(expired: Bool, running: Bool) -> String {
        if expired { return "Done" }
        if running { return "Timer running" }
        if timer == nil { return "\(CookClock.mmss(Double(duration))) timer" }
        return "Paused"
    }

    private func controlButton(system: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.title3.weight(.bold))
                .foregroundStyle(filled ? .white : Color.accentColor)
                .frame(width: 52, height: 52)
                .background {
                    if filled {
                        Circle().fill(Color.accentColor)
                    } else {
                        Circle().strokeBorder(Color.accentColor, lineWidth: 1.5)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}
