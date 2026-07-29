//
//  MealPlanEntry.swift
//  RecipeKit
//
//  One recipe assigned to one day of the meal plan. Persisted locally via
//  `MealPlanStore` (same pattern as `PendingJob` / `PendingJobStore`).
//
//  IMPORTANT — why this denormalizes recipe fields: the recipe list itself is
//  NOT persisted (the backend has no "list my vault" endpoint, so
//  `PendingJobsModel.recipes` is in-memory per session and empty after a
//  relaunch). If an assignment stored only `recipeId`, a saved plan would render
//  blank on next launch because the full `Recipe` wouldn't be in memory to
//  supply a title/image. So each entry carries a small display snapshot
//  (`recipeTitle`, `recipeImageURL`) captured at assign time.
//

import Foundation

public struct MealPlanEntry: Codable, Identifiable, Hashable {
    /// Assignment id (not the recipe id) — lets the same recipe be assigned more
    /// than once and removed individually.
    public let id: String
    /// The day this is planned for, as a stable local-day key: "yyyy-MM-dd".
    public let dayKey: String
    /// Reference to the source recipe (may not be resolvable in a later session).
    public let recipeId: String
    /// Snapshot of the recipe title, so the card renders without the full Recipe.
    public let recipeTitle: String
    /// Snapshot of the recipe image URL (nil if the recipe had no image).
    public let recipeImageURL: String?
    /// When it was assigned — orders entries within a day.
    public let addedAt: Date

    public init(
        id: String = UUID().uuidString,
        dayKey: String,
        recipeId: String,
        recipeTitle: String,
        recipeImageURL: String? = nil,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.dayKey = dayKey
        self.recipeId = recipeId
        self.recipeTitle = recipeTitle
        self.recipeImageURL = recipeImageURL
        self.addedAt = addedAt
    }
}
