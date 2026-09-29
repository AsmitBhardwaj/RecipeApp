//
//  PlanReminderCard.swift
//  RecipeApp
//
//  The day-6 nudge card under the last dinner on "Your week". Offer → (permission
//  prompt) → "Reminder set for <weekday> ✓", or "Turn on notifications in
//  Settings" when the OS permission is denied.
//

import SwiftUI

struct PlanReminderCard: View {
    @EnvironmentObject private var reminders: PlanReminderModel

    var body: some View {
        switch reminders.cardState {
        case .hidden:
            EmptyView()
        case .offer:
            card(text: "Get a nudge on day 6 to plan next week", buttonTitle: "Remind me", icon: "bell",
                 action: reminders.remindMe, dismissible: true)
        case .needsSettings:
            card(text: "Turn on notifications in Settings", buttonTitle: "Open Settings", icon: "gearshape",
                 action: reminders.openSettings, dismissible: true)
        case .confirmed(let weekday):
            HStack(spacing: 10) {
                Image(systemName: "bell.badge.fill").foregroundStyle(Color.accentColor).accessibilityHidden(true)
                Text("Reminder set for \(weekday) ✓")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dinnerCardSurface()
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Reminder set for \(weekday)")
        }
    }

    private func card(text: String, buttonTitle: String, icon: String, action: @escaping () -> Void,
                      dismissible: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "bell").foregroundStyle(Color.accentColor).padding(.top, 2).accessibilityHidden(true)
                Text(text)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if dismissible {
                    Button { reminders.dismissCard() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.textSecondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, -12).padding(.trailing, -12)
                    .accessibilityLabel("Dismiss reminder suggestion")
                }
            }
            PlanActionButton(title: buttonTitle, icon: icon, style: .tinted, action: action)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dinnerCardSurface()
    }
}
