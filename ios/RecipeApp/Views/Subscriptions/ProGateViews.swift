//
//  ProGateViews.swift
//  RecipeApp
//
//  Small, reusable locked-state views shown to free users in place of Pro
//  content. Each takes an `onUpgrade` closure that presents the Platter Pro
//  paywall. Styling reuses the app's tokens (surface, hairline, accent,
//  sageLight) so a locked state reads as part of the same system.
//

import SwiftUI

/// Pantry "Suggestions" locked state: one line of explanation + a "Try Platter
/// Pro" button. Free users can still add/edit pantry items; only this section is
/// gated.
struct ProSuggestionsLockedCard: View {
    let onUpgrade: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 40)
                    .background(Color.sageLight.opacity(0.42), in: Circle())
                    .accessibilityHidden(true)
                Text("Get recipe ideas from what's in your kitchen with Platter Pro.")
                    .font(.subheadline)
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: onUpgrade) {
                Text("Try Platter Pro")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.hairline, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recipe suggestions are a Platter Pro feature")
        .accessibilityHint("Opens Platter Pro")
        .accessibilityAddTraits(.isButton)
    }
}

/// Nutrition locked state: a single row shown instead of the calories/macros.
/// The whole row is tappable and opens the paywall.
struct ProNutritionLockedRow: View {
    let onUpgrade: () -> Void

    var body: some View {
        Button(action: onUpgrade) {
            HStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text("See calories & macros with Platter Pro")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.textPrimary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.textSecondary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.hairline, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("See calories and macros with Platter Pro")
        .accessibilityHint("Opens Platter Pro")
    }
}
