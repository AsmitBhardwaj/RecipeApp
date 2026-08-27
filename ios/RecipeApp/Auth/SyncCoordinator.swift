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

@MainActor
final class SyncCoordinator: ObservableObject {
    /// The account scope the view models use to open their local stores.
    let userScope: String

    private let engine: SyncEngine
    private let applier: LocalSyncApplier
    private let metadata: SyncMetadataStore
    private let client: SyncClient

    private var pushTask: Task<Void, Never>?
    private var isSyncing = false

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
        self.engine = SyncEngine(
            transport: client,
            outbox: SyncOutbox(userId: userId, suiteName: suiteName),
            cursorStore: SyncCursorStore(userId: userId, suiteName: suiteName),
            apply: { change in applier.apply(change) }
        )
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
        do {
            try await engine.sync()
            try await hydrateIfNeeded()
        } catch {
            // Offline / unauthorized / server error: keep the outbox and cursor;
            // the next trigger (foreground, next mutation) retries.
        }
    }

    /// Fire-and-forget trigger for use from SwiftUI lifecycle hooks.
    func triggerSync() {
        Task { await sync() }
    }

    private func hydrateIfNeeded() async throws {
        let ids = Array(applier.pendingRecipeHydration)
        guard !ids.isEmpty else { return }
        let recipes = try await client.recipes(ids: ids)
        applier.hydrate(recipes)
    }
}
