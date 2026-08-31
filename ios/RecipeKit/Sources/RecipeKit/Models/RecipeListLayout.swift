//
//  RecipeListLayout.swift
//  RecipeKit
//
//  Pure layout decisions for the recipe list, factored out of the SwiftUI view so
//  the rule can be unit-tested. The one rule that matters: the "no recipes yet"
//  empty state must NOT swallow in-flight or failed job cards — otherwise a user's
//  first share (empty finished-recipe list, one job processing) shows "No recipes
//  yet" and the share looks lost.
//

import Foundation

public enum RecipeListLayout {
    /// Whether to show the empty-state placeholder instead of the list. Only true
    /// when there is genuinely nothing to render: no finished recipes AND no
    /// pending (processing) cards AND no failed cards.
    public static func showsEmptyState(
        recipeCount: Int,
        pendingCount: Int,
        failedCount: Int
    ) -> Bool {
        recipeCount == 0 && pendingCount == 0 && failedCount == 0
    }
}
