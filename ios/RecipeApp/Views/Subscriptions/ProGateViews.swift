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

// Nutrition's locked state (free account, recipe has nutrition) is now the
// full-size locked card built directly in RecipeDetailView — see
// `lockedNutritionCard` there — not this row.
