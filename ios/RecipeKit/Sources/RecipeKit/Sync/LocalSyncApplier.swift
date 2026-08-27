//
//  LocalSyncApplier.swift
//  RecipeKit
//
//  Writes a pulled (or conflict-adopted) `SyncChange` into the correct
//  account-scoped local store, under apply-side last-writer-wins: a change older
//  than what we already hold (per SyncMetadataStore) is ignored. This is the
//  `apply` closure handed to `SyncEngine` in the view-model wiring chunk.
//
//  Recipe CONTENT isn't carried in the library collection, so a library entry
//  for a recipe whose body isn't on this device is recorded as a hydration need;
//  the caller batch-fetches those via SyncClient.recipes(ids:).
//

import Foundation

public final class LocalSyncApplier {
    private let recipeStore: RecipeStore
    private let mealStore: MealPlanStore
    private let groceryStore: GroceryCheckStore
    private let cookbookStore: CookbookStore
    private let membershipStore: CookbookMembershipStore
    private let metadata: SyncMetadataStore

    /// Recipe ids referenced by pulled library entries whose bodies aren't local
    /// yet. Drained by the caller after a pull to hydrate via /v1/recipes/batch.
    public private(set) var pendingRecipeHydration: Set<String> = []

    public init(userId: String, suiteName: String = AppGroup.identifier) {
        self.recipeStore = RecipeStore(suiteName: suiteName, userScope: userId)
        self.mealStore = MealPlanStore(suiteName: suiteName, userScope: userId)
        self.groceryStore = GroceryCheckStore(suiteName: suiteName, userScope: userId)
        self.cookbookStore = CookbookStore(suiteName: suiteName, userScope: userId)
        self.membershipStore = CookbookMembershipStore(suiteName: suiteName, userScope: userId)
        self.metadata = SyncMetadataStore(userId: userId, suiteName: suiteName)
    }

    /// Test seam: all stores share one injected `UserDefaults`, scoped by userId.
    public init(userId: String, defaults: UserDefaults) {
        self.recipeStore = RecipeStore(defaults: defaults, userScope: userId)
        self.mealStore = MealPlanStore(defaults: defaults, userScope: userId)
        self.groceryStore = GroceryCheckStore(defaults: defaults, userScope: userId)
        self.cookbookStore = CookbookStore(defaults: defaults, userScope: userId)
        self.membershipStore = CookbookMembershipStore(defaults: defaults, userScope: userId)
        self.metadata = SyncMetadataStore(userId: userId, defaults: defaults)
    }

    /// Apply one remote change under last-writer-wins.
    public func apply(_ change: SyncChange) {
        if let known = metadata.updatedAt(change.collection, change.itemId), change.updatedAt < known {
            return  // we already hold a newer version
        }
        switch change.collection {
        case .mealPlan: applyMealPlan(change)
        case .groceryManual: applyGroceryManual(change)
        case .groceryCheck: applyGroceryCheck(change)
        case .cookbook: applyCookbook(change)
        case .cookbookMembership: applyMembership(change)
        case .library: applyLibrary(change)
        }
        metadata.setUpdatedAt(change.collection, change.itemId, change.updatedAt)
    }

    // MARK: - Per-collection

    private func applyMealPlan(_ change: SyncChange) {
        mealStore.remove(id: change.itemId)  // upsert = remove-then-insert
        guard !change.deleted, let entry = SyncCodec.decode(MealPlanEntry.self, from: change.payload) else { return }
        mealStore.add(entry)
    }

    private func applyGroceryManual(_ change: SyncChange) {
        groceryStore.removeManual(id: change.itemId)
        guard !change.deleted, let item = SyncCodec.decode(GroceryManualItem.self, from: change.payload) else { return }
        groceryStore.addManual(item)
    }

    private func applyGroceryCheck(_ change: SyncChange) {
        let checked = !change.deleted && (SyncCodec.decode(GroceryCheckPayload.self, from: change.payload)?.checked ?? false)
        groceryStore.setChecked(change.itemId, checked)
    }

    private func applyCookbook(_ change: SyncChange) {
        if change.deleted {
            cookbookStore.remove(id: change.itemId)
            membershipStore.removeCookbook(change.itemId)
            return
        }
        guard let cookbook = SyncCodec.decode(Cookbook.self, from: change.payload) else { return }
        cookbookStore.upsert(cookbook)
    }

    private func applyMembership(_ change: SyncChange) {
        guard let link = SyncCodec.decode(MembershipPayload.self, from: change.payload) else { return }
        var current = membershipStore.cookbookIds(forRecipe: link.recipeId)
        if change.deleted {
            current.removeAll { $0 == link.cookbookId }
        } else if !current.contains(link.cookbookId) {
            current.append(link.cookbookId)
        }
        membershipStore.setCookbooks(forRecipe: link.recipeId, to: current)
    }

    private func applyLibrary(_ change: SyncChange) {
        if change.deleted {
            recipeStore.remove(recipeId: change.itemId)
            pendingRecipeHydration.remove(change.itemId)
            return
        }
        // Membership present; if we don't have the body, mark it for hydration.
        let haveBody = recipeStore.all().contains { $0.recipeId == change.itemId }
        if !haveBody {
            pendingRecipeHydration.insert(change.itemId)
        }
    }

    /// Insert hydrated recipe bodies (fetched via /v1/recipes/batch) and clear
    /// them from the pending set.
    public func hydrate(_ recipes: [Recipe]) {
        for recipe in recipes {
            recipeStore.upsert(recipe)
            pendingRecipeHydration.remove(recipe.recipeId)
        }
    }
}
