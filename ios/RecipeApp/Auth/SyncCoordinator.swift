//
//  SyncCoordinator.swift
//  RecipeApp
//
//  The app-side hub for Stage 2b sync. Owns the SyncEngine (transport +
//  outbox + cursor), the LocalSyncApplier, and the shared SyncMetadataStore for
//  the signed-in account, and exposes:
//    • record(...)  — the view models call this after a local mutation; it stamps
//                     the metadata clock, queues the change, and schedules a
//                     debounced push.
//    • sync()       — push + pull + recipe hydration; run on sign-in and on
//                     foreground. Offline/unauthorized errors are swallowed so
//                     the outbox simply survives until the next trigger.
//
//  Constructed with the verified user id (for account scoping) and a token
//  provider (AuthModel.validAccessToken), so every request carries a fresh
//  Bearer token.
//

import Foundation
import RecipeKit

/// A live view model that seeds itself from a disk store and therefore needs a
/// nudge after a sync pull writes new data straight to disk (the applier never
/// touches @Published state). Implementations re-read their store, adding only
/// newly-arrived items and never dropping or reordering anything resolved this
/// session (merge-never-overwrite).
@MainActor
protocol SyncRefreshable: AnyObject {
    func refreshFromStore()
}

@MainActor
final class SyncCoordinator: ObservableObject {
    /// The account scope the view models use to open their local stores.
    let userScope: String

    private let engine: SyncEngine
    private let applier: LocalSyncApplier
    private let metadata: SyncMetadataStore
    private let client: SyncClient
    /// Reuses the same fresh-Bearer-token provider as sync, so pantry suggestions
    /// (an account-scoped endpoint) authenticate identically. Built lazily —
    /// suggestions are only fetched from the Kitchen tab's Pantry segment.
    private let pantryClient: PantrySuggestionsClient
    private let budgetClient: BudgetPlanClient

    private var pushTask: Task<Void, Never>?
    private var isSyncing = false

    /// Live models that seed from disk stores and need refreshing after a pull
    /// writes new data (PendingJobsModel, MealPlanModel, PantryModel,
    /// CookbooksModel). Held weakly so a torn-down view's model doesn't leak or
    /// keep firing; nil slots are pruned on notify. Several instances of the same
    /// model type can register (e.g. the Grocery tab and Meal Plan tab each own a
    /// MealPlanModel) — every one gets refreshed.
    private struct WeakRefreshable { weak var value: (any SyncRefreshable)? }
    private var refreshables: [WeakRefreshable] = []

    init(
        userId: String,
        tokenProvider: @escaping () async throws -> String,
        suiteName: String = AppGroup.identifier
    ) {
        self.userScope = userId
        self.metadata = SyncMetadataStore(userId: userId, suiteName: suiteName)
        let applier = LocalSyncApplier(userId: userId, suiteName: suiteName)
        self.applier = applier
        self.client = SyncClient(accessTokenProvider: tokenProvider)
        self.pantryClient = PantrySuggestionsClient(accessTokenProvider: tokenProvider)
        self.budgetClient = BudgetPlanClient(
            accessTokenProvider: tokenProvider
        )
        self.engine = SyncEngine(
            transport: client,
            outbox: SyncOutbox(userId: userId, suiteName: suiteName),
            cursorStore: SyncCursorStore(userId: userId, suiteName: suiteName),
            apply: { change in applier.apply(change) }
        )
    }

    // MARK: - Live-model refresh registration

    /// Register a disk-backed model to be refreshed after a pull applies remote
    /// changes. Idempotent-ish: callers register once in their `init`.
    func registerRefreshable(_ refreshable: any SyncRefreshable) {
        refreshables.removeAll { $0.value == nil }
        guard !refreshables.contains(where: { $0.value === refreshable }) else { return }
        refreshables.append(WeakRefreshable(value: refreshable))
    }

    /// Ask every live model to merge in whatever the pull just wrote to disk.
    private func notifyRefreshables() {
        refreshables.removeAll { $0.value == nil }
        for slot in refreshables { slot.value?.refreshFromStore() }
    }

    // MARK: - Recording local mutations

    /// Record a local mutation for sync: stamp the metadata clock (so apply-side
    /// LWW knows our version), queue it, and schedule a debounced push.
    func record(_ collection: SyncCollection, itemId: String, payload: String?, deleted: Bool = false) {
        let now = syncNowMillis()
        metadata.setUpdatedAt(collection, itemId, now)
        engine.record(SyncChange(collection: collection, itemId: itemId, updatedAt: now, deleted: deleted, payload: payload))
        schedulePush()
    }

    private func schedulePush() {
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)  // debounce bursts
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    // MARK: - Sync

    /// Push local changes, pull remote ones, and hydrate any recipe bodies a
    /// pulled library entry referenced. Safe to call repeatedly; overlapping
    /// calls are coalesced.
    func sync() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        let revisionBefore = applier.appliedRevision
        do {
            try await engine.sync()
            try await hydrateIfNeeded()
        } catch {
            // Offline / unauthorized / server error: keep the outbox and cursor;
            // the next trigger (foreground, next mutation) retries.
        }
        // Only refresh the live models when the pull/hydrate actually wrote new
        // data to disk. A plain local-edit push pulls nothing new (our own change
        // is behind the cursor), so this stays a no-op then — no spurious
        // app-wide re-renders on every edit.
        if applier.appliedRevision != revisionBefore {
            notifyRefreshables()
        }
    }

    /// Fire-and-forget trigger for use from SwiftUI lifecycle hooks.
    func triggerSync() {
        Task { await sync() }
    }

    // MARK: - Pantry suggestions

    /// Fetch pantry recipe suggestions for the signed-in account. `pantryOverride`
    /// lets the caller match against the LOCAL pantry (what's on screen) rather
    /// than waiting for the pantry to sync to the server first.
    func pantrySuggestions(
        limit: Int = 20,
        pantryOverride: [String]? = nil,
        allowGeneration: Bool = true
    ) async throws -> PantrySuggestionsResponse {
        try await pantryClient.suggestions(
            limit: limit, pantryOverride: pantryOverride, allowGeneration: allowGeneration
        )
    }

    // MARK: - Plan on a Budget

    /// Generate a budget plan for the signed-in account (POST /v1/meal-plan/budget).
    /// Pro-gated server-side; the client also sends its cached Pro claim.
    func budgetPlan(
        budget: Int,
        householdSize: Int,
        dietaryPreferences: [String],
        pantryItems: [String],
        country: String? = nil,
        areaType: String? = nil
    ) async throws -> BudgetPlanResponse {
        try await budgetClient.generate(
            budget: budget,
            householdSize: householdSize,
            dietaryPreferences: dietaryPreferences,
            pantryItems: pantryItems,
            country: country,
            areaType: areaType
        )
    }

    private func hydrateIfNeeded() async throws {
        let ids = Array(applier.pendingRecipeHydration)
        guard !ids.isEmpty else { return }
        let recipes = try await client.recipes(ids: ids)
        applier.hydrate(recipes)
        // Bodies are now on disk (RecipeStore). The revision bump inside
        // hydrate() makes sync() nudge the live models (see notifyRefreshables),
        // so a recipe pulled from another device resolves this session rather
        // than only after the next cold launch.
    }
}
