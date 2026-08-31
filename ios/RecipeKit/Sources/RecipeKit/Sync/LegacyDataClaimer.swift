//
//  LegacyDataClaimer.swift
//  RecipeKit
//
//  Stage 4 — "claim your data". Before accounts existed, the local stores wrote
//  to un-namespaced (nil-scope) UserDefaults keys. Now that sign-in is mandatory
//  (Stage 3) and every store is account-scoped by user id (Stage 2b), that
//  pre-account data would be invisible to a signed-in account. This one-time
//  migration copies each legacy record into the signed-in account's scoped store
//  AND enqueues it into that account's sync outbox, so it both shows locally and
//  uploads to the server (reaching the user's other devices).
//
//  Runs at most once per device: the FIRST account to sign in claims the legacy
//  data, then the legacy keys are cleared and a device-global flag is set. A
//  second account on the same device starts empty (its data arrives via pull).
//
//  Recipe BODIES are not uploaded (there is no recipe-write endpoint — recipes
//  are created only by the extraction pipeline, and are cached server-side by
//  canonical video id). The claim uploads library MEMBERSHIP and keeps the body
//  in the local scoped RecipeStore, matching how a normal "save" syncs.
//

import Foundation

/// Per-category counts of what the claim migrated, for the confirmation toast.
public struct ClaimSummary: Equatable, Sendable {
    public let recipes: Int
    public let cookbooks: Int
    public let mealPlanEntries: Int
    public let groceryItems: Int   // manual items + checked lines

    public init(recipes: Int, cookbooks: Int, mealPlanEntries: Int, groceryItems: Int) {
        self.recipes = recipes
        self.cookbooks = cookbooks
        self.mealPlanEntries = mealPlanEntries
        self.groceryItems = groceryItems
    }

    public var total: Int { recipes + cookbooks + mealPlanEntries + groceryItems }
    public var isEmpty: Bool { total == 0 }
}

public struct LegacyDataClaimer {
    /// Device-global (NOT account-scoped): legacy data belongs to whoever used the
    /// device before accounts, and is claimed exactly once regardless of account.
    static let claimedFlagKey = "legacy_data_claimed_v1"

    private let userId: String
    private let defaults: UserDefaults

    public init(userId: String, suiteName: String = AppGroup.identifier) {
        self.userId = userId
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    /// Test/seam initializer: all stores share one injected `UserDefaults`.
    public init(userId: String, defaults: UserDefaults) {
        self.userId = userId
        self.defaults = defaults
    }

    public var alreadyClaimed: Bool { defaults.bool(forKey: Self.claimedFlagKey) }

    /// Migrate legacy data into this account if it hasn't been claimed yet.
    /// Returns a non-empty summary if anything moved; `nil` if already claimed or
    /// there was nothing to claim (the flag is set either way, so this is a no-op
    /// on every subsequent launch).
    @discardableResult
    public func claimIfNeeded() -> ClaimSummary? {
        guard !alreadyClaimed else { return nil }

        // Legacy (nil-scope) sources.
        let legacyRecipes = RecipeStore(defaults: defaults, userScope: nil)
        let legacyMeals = MealPlanStore(defaults: defaults, userScope: nil)
        let legacyGrocery = GroceryCheckStore(defaults: defaults, userScope: nil)
        let legacyCookbooks = CookbookStore(defaults: defaults, userScope: nil)
        let legacyMembership = CookbookMembershipStore(defaults: defaults, userScope: nil)

        // Account-scoped destinations.
        let recipes = RecipeStore(defaults: defaults, userScope: userId)
        let meals = MealPlanStore(defaults: defaults, userScope: userId)
        let grocery = GroceryCheckStore(defaults: defaults, userScope: userId)
        let cookbooks = CookbookStore(defaults: defaults, userScope: userId)
        let membership = CookbookMembershipStore(defaults: defaults, userScope: userId)

        let outbox = SyncOutbox(userId: userId, defaults: defaults)
        let metadata = SyncMetadataStore(userId: userId, defaults: defaults)

        // Enqueue a change into the outbox and stamp the LWW clock so a later
        // pull can't clobber what we just claimed.
        func stage(_ collection: SyncCollection, _ itemId: String, _ payload: String?, _ updatedAt: Int64) {
            metadata.setUpdatedAt(collection, itemId, updatedAt)
            outbox.enqueue(SyncChange(collection: collection, itemId: itemId, updatedAt: updatedAt, payload: payload))
        }

        let now = syncNowMillis()

        // --- Recipes (library membership; body stays local) ---
        let allRecipes = legacyRecipes.all()
        for recipe in allRecipes {
            recipes.upsert(recipe)
            let iso = ISO8601DateFormatter().string(from: Date())
            stage(.library, recipe.recipeId, SyncCodec.encode(LibraryPayload(recipeId: recipe.recipeId, savedAt: iso)), now)
        }

        // --- Cookbooks ---
        let allCookbooks = legacyCookbooks.all()
        for cookbook in allCookbooks {
            cookbooks.upsert(cookbook)
            stage(.cookbook, cookbook.id, SyncCodec.encode(cookbook), millis(cookbook.createdAt))
        }

        // --- Cookbook memberships ---
        let allMemberships = legacyMembership.allMemberships()
        var byRecipe: [String: [String]] = [:]
        for link in allMemberships {
            byRecipe[link.recipeId, default: []].append(link.cookbookId)
            let itemId = MembershipPayload.itemId(cookbookId: link.cookbookId, recipeId: link.recipeId)
            stage(.cookbookMembership, itemId, SyncCodec.encode(MembershipPayload(cookbookId: link.cookbookId, recipeId: link.recipeId)), now)
        }
        for (recipeId, cookbookIds) in byRecipe {
            membership.setCookbooks(forRecipe: recipeId, to: cookbookIds)
        }

        // --- Meal plan ---
        let allMeals = legacyMeals.all()
        for entry in allMeals {
            meals.add(entry)
            stage(.mealPlan, entry.id, SyncCodec.encode(entry), millis(entry.addedAt))
        }

        // --- Grocery: manual items + checked lines ---
        let manualItems = legacyGrocery.manualItems()
        for item in manualItems {
            grocery.addManual(item)
            stage(.groceryManual, item.id, SyncCodec.encode(item), millis(item.addedAt))
        }
        let checkedKeys = legacyGrocery.checkedKeys()
        for key in checkedKeys {
            grocery.setChecked(key, true)
            stage(.groceryCheck, key, SyncCodec.encode(GroceryCheckPayload(checked: true)), now)
        }

        // Mark claimed and clear legacy sources (the scoped copy + outbox are the
        // safe home now; upload retries from the outbox if we're offline).
        markClaimed()
        clearLegacy()

        let summary = ClaimSummary(
            recipes: allRecipes.count,
            cookbooks: allCookbooks.count,
            mealPlanEntries: allMeals.count,
            groceryItems: manualItems.count + checkedKeys.count
        )
        return summary.isEmpty ? nil : summary
    }

    // MARK: - Helpers

    private func millis(_ date: Date) -> Int64 { syncNowMillis(date) }

    private func markClaimed() {
        defaults.set(true, forKey: Self.claimedFlagKey)
    }

    /// Remove the legacy (nil-scope) keys so the data isn't re-claimed and doesn't
    /// linger. Uses each store's own base key via a nil-scope removeAll.
    private func clearLegacy() {
        for key in [
            "recipes_v1",
            "meal_plan_entries_v1",
            "grocery_checked_keys_v1",
            "grocery_manual_items_v1",
            "cookbooks_v1",
            "cookbook_membership_v1",
        ] {
            defaults.removeObject(forKey: key)
        }
    }
}
