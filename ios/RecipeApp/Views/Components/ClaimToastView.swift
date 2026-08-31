//
//  ClaimToastView.swift
//  RecipeApp
//
//  Stage 4 confirmation toast. Shown once, non-blocking, after the "claim your
//  data" migration copies a user's pre-account data into their signed-in account
//  on first sign-in. Auto-dismisses; carries no action — the data is already
//  migrated and uploading.
//

import SwiftUI
import RecipeKit

struct ClaimToastView: View {
    let summary: ClaimSummary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Added your existing data")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.textPrimary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.textSecondary.opacity(0.15)))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.horizontal, 16)
    }

    /// "12 recipes · 3 lists" — only the non-zero categories, pluralized.
    private var detail: String {
        var parts: [String] = []
        if summary.recipes > 0 { parts.append(count(summary.recipes, "recipe")) }
        if summary.cookbooks > 0 { parts.append(count(summary.cookbooks, "cookbook")) }
        if summary.mealPlanEntries > 0 { parts.append(count(summary.mealPlanEntries, "meal")) }
        if summary.groceryItems > 0 { parts.append(count(summary.groceryItems, "grocery item")) }
        return parts.joined(separator: " · ")
    }

    private func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}
