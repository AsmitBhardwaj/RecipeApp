//
//  PendingJobsModel.swift
//  RecipeApp
//
//  The observable coordinator behind the §3 processing-card experience. It owns
//  the recipe list state AND the in-flight jobs, so the Recipes tab can render a
//  processing card the instant a share happens and morph it into the finished
//  recipe when the job resolves.
//
//  Durability lives in `PendingJobStore` (App Group): every submitted job is
//  persisted keyed by `job_id` before we start polling, so a job survives the
//  app being backgrounded or force-quit mid-poll and is picked back up by
//  `reconcile()` on the next launch/foreground. This is the client-side half of
//  CLAUDE.md §6's "foreground check of the App Group's pending-jobs list."
//
//  It builds only on the job-level provider primitives (`submitJob` + `fetchJob`)
//  — never the blocking `submitRecipe` — so the poll is driven by a job_id we
//  hold, not hidden inside a synchronous await.
//

import Foundation
import RecipeKit

@MainActor
final class PendingJobsModel: ObservableObject {

    /// Finished recipes for the list (newest first). Accumulates this session;
    /// `fetchRecipes()` seeds it (empty against the real backend today).
    @Published private(set) var recipes: [Recipe] = []
    /// Jobs still queued/processing — rendered as skeleton cards.
    @Published private(set) var pending: [PendingJob] = []
    /// Jobs that failed, held in memory until the user dismisses the card. Not
    /// persisted: the durable store only holds not-yet-resolved jobs.
    @Published private(set) var failed: [FailedJob] = []
    /// Set once when a job first transitions to failed while the app is active,
    /// driving a one-time alert *in addition to* the persistent failed card.
    /// Cleared on dismiss. Not persisted — failed jobs aren't persisted, so
    /// there's nothing to re-alert about on relaunch.
    @Published private(set) var failureAlert: FailureAlert?
    /// Initial recipe-fetch state for the list screen.
    @Published private(set) var loadState: LoadState = .loading

    enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    struct FailedJob: Identifiable, Equatable {
        let jobId: String
        let url: String
        let message: String
        /// Backend `error_code`, so the card can decide whether to offer the
        /// "Paste recipe text" remedy (see RecipeProviderError.canPasteText).
        let errorCode: String?
        var id: String { jobId }

        /// Whether this failure can be recovered by pasting the recipe text.
        var canPasteText: Bool { RecipeProviderError.canPasteText(code: errorCode) }
    }

    /// A one-shot failure surfaced as an alert. Identifiable by job id so
    /// `.alert(isPresented:presenting:)` keys on the specific failure.
    struct FailureAlert: Identifiable, Equatable {
        let id: String   // jobId
        let message: String
    }

    private let provider: RecipeProvider
    private let store: PendingJobStore
    /// On-device cache of completed recipes so the list survives full relaunches
    /// (the backend has no vault endpoint). Written in `handleComplete`.
    private let recipeStore: RecipeStore
    /// Job ids with an in-flight poll task, so `reconcile()` and `submit()` never
    /// start a second poll for the same job.
    private var activePolls: Set<String> = []
    /// Job ids we've already surfaced the failure alert for this session, so the
    /// same failure never pops the alert twice. Not persisted (resets each launch).
    private var alertedJobIds: Set<String> = []
    /// Whether the one-time recipe seed has succeeded. Guards `load()` so a
    /// re-fired `.task` can never re-run it and clobber recipes resolved this
    /// session (see `load()`).
    private var hasLoaded = false

    /// Poll cadence/budget — mirrors `APIRecipeProvider.pollUntilRecipe`.
    private let pollInterval: Duration = .seconds(1.5)
    private let maxWait: Duration = .seconds(120)

    /// Sync hub (nil in previews/unscoped builds → no sync recording).
    private let sync: SyncCoordinator?

    init(
        provider: RecipeProvider,
        userScope: String? = nil,
        sync: SyncCoordinator? = nil,
        store: PendingJobStore = PendingJobStore()
    ) {
        self.provider = provider
        self.sync = sync
        self.store = store
        // The recipe cache is account-scoped; the pending-jobs queue stays
        // device-local (transient, reconciled per Stage 6).
        self.recipeStore = RecipeStore(userScope: userScope)
        // Show any persisted jobs immediately (e.g. submitted last session, or by
        // the Share Extension while the app was closed) before the first re-poll.
        self.pending = store.all()
        // Seed the list from the on-device cache so recipes extracted in earlier
        // sessions are present the instant the app launches, before any network.
        self.recipes = recipeStore.all()
    }

    // MARK: - Initial load

    /// Seed the recipe list, exactly once. Against the real backend this returns
    /// empty (no vault endpoint); the mock returns samples.
    ///
    /// Two hard rules keep this from wiping the list:
    ///  1. Run-once — once it has succeeded, subsequent calls (e.g. a re-fired
    ///     `.task`) are no-ops. Without this, a re-fire would flip `loadState`
    ///     and re-fetch, erasing recipes resolved this session.
    ///  2. Merge, never overwrite — fetched recipes are added to whatever is
    ///     already present, so a poll that inserted a recipe before this ran is
    ///     preserved. (Since `fetchRecipes()` returns [] today, this is future-
    ///     proofing; the run-once guard is what fixes the bug now.)
    func load() async {
        guard !hasLoaded else { return }
        loadState = .loading
        do {
            let fetched = try await provider.fetchRecipes()
            let known = Set(recipes.map(\.recipeId))
            recipes.append(contentsOf: fetched.filter { !known.contains($0.recipeId) })
            hasLoaded = true
            loadState = .loaded
        } catch let error as RecipeProviderError {
            loadState = .failed(error.userMessage)
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Submit

    /// Enqueue a URL and start tracking it. Returns as soon as the job is
    /// persisted (submit-and-close). Throws only on the immediate enqueue
    /// failure (invalid URL / offline / HTTP error) so the Add sheet can show it;
    /// everything after enqueue plays out on the processing card.
    func submit(url: String) async throws {
        let job = try await provider.submitJob(url: url)
        let entry = PendingJob(
            jobId: job.jobId,
            url: url,
            submittedAt: Date(),
            lastStatus: job.status
        )
        store.upsert(entry)
        pending = store.all()
        startPolling(jobId: job.jobId)
    }

    // MARK: - Reconciliation

    /// Called on launch and whenever the app returns to the foreground. Re-polls
    /// every persisted job so anything that finished, failed, or made progress
    /// while we were backgrounded or killed gets resolved — not just jobs
    /// submitted this session.
    func reconcile() {
        pending = store.all()
        for job in pending {
            startPolling(jobId: job.jobId)
        }
    }

    /// Dismiss a failed card (removes the in-memory entry; the store no longer
    /// holds it).
    func dismissFailed(jobId: String) {
        failed.removeAll { $0.jobId == jobId }
    }

    /// Dismiss the one-time failure alert. The failed card stays in the list for
    /// detailed review.
    func clearFailureAlert() {
        failureAlert = nil
    }

    /// Retry a failed job with user-pasted recipe text. On success the recipe is
    /// added to the list exactly like a normal completion (persisted + library
    /// sync) and the failed card is cleared. Throws `RecipeProviderError` so the
    /// paste screen can show a specific failure state.
    @discardableResult
    func submitPastedText(jobId: String, text: String) async throws -> Recipe {
        let envelope = try await provider.submitPastedText(jobId: jobId, text: text)
        switch envelope.job.status {
        case .complete:
            guard let recipe = envelope.recipe else {
                throw RecipeProviderError.invalidResponse("job completed but carried no recipe")
            }
            handleComplete(jobId: jobId, envelope: envelope)  // insert + persist + sync
            failed.removeAll { $0.jobId == jobId }            // clear the failed card
            return recipe
        case .failed:
            throw RecipeProviderError.jobFailed(code: envelope.job.errorCode, message: envelope.job.error)
        case .queued, .processing:
            throw RecipeProviderError.invalidResponse("paste did not reach a terminal state")
        }
    }

    // MARK: - Polling

    private func startPolling(jobId: String) {
        guard !activePolls.contains(jobId) else { return }
        activePolls.insert(jobId)
        Task { await poll(jobId: jobId) }
    }

    private func poll(jobId: String) async {
        defer { activePolls.remove(jobId) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: maxWait)

        while clock.now < deadline {
            do {
                let envelope = try await provider.fetchJob(jobId: jobId)
                switch envelope.job.status {
                case .queued, .processing:
                    store.updateStatus(jobId: jobId, envelope.job.status)
                    pending = store.all()
                case .complete:
                    handleComplete(jobId: jobId, envelope: envelope)
                    return
                case .failed:
                    let message = RecipeProviderError
                        .jobFailed(code: envelope.job.errorCode, message: envelope.job.error)
                        .userMessage
                    handleFailed(jobId: jobId, message: message, url: envelope.job.url,
                                 code: envelope.job.errorCode)
                    return
                }
            } catch RecipeProviderError.httpStatus(404) {
                // Job genuinely not on the server — terminal; clean it up.
                handleFailed(jobId: jobId, message: RecipeProviderError.httpStatus(404).userMessage)
                return
            } catch {
                // Transient (offline / timeout / 5xx): keep the card and retry on
                // the next tick — or the next foreground reconcile if we're killed.
            }
            try? await Task.sleep(for: pollInterval)
        }
        // Budget exhausted while the app stayed open: leave the entry persisted so
        // the next foreground reconcile resumes it. The card stays "processing".
    }

    private func handleComplete(jobId: String, envelope: JobEnvelope) {
        if let recipe = envelope.recipe {
            recipes.removeAll { $0.recipeId == recipe.recipeId }
            recipes.insert(recipe, at: 0)
            // Persist to the on-device cache so it survives a full relaunch.
            recipeStore.upsert(recipe)
            // Sync library membership (the recipe body is already in the server
            // cache from extraction, so only the membership entry is pushed).
            let iso = ISO8601DateFormatter().string(from: Date())
            sync?.record(.library, itemId: recipe.recipeId,
                         payload: SyncCodec.encode(LibraryPayload(recipeId: recipe.recipeId, savedAt: iso)))
        }
        store.remove(jobId: jobId)
        pending = store.all()
    }

    private func handleFailed(jobId: String, message: String, url: String? = nil, code: String? = nil) {
        let jobURL = url ?? pending.first(where: { $0.jobId == jobId })?.url ?? ""
        if !failed.contains(where: { $0.jobId == jobId }) {
            failed.append(FailedJob(jobId: jobId, url: jobURL, message: message, errorCode: code))
        }
        // Surface a one-time alert on the transition to failed. Once per jobId
        // per session; a second concurrent failure keeps its card but doesn't
        // stomp an unacknowledged alert.
        if !alertedJobIds.contains(jobId) {
            alertedJobIds.insert(jobId)
            if failureAlert == nil {
                failureAlert = FailureAlert(id: jobId, message: message)
            }
        }
        store.remove(jobId: jobId)
        pending = store.all()
    }
}
