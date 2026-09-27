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
import os
import RecipeKit

private let pollLog = Logger(subsystem: "com.recipeapp", category: "PendingJobs")

@MainActor
final class PendingJobsModel: ObservableObject, SyncRefreshable {

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
        /// Backend `error_code`, carried through so the alert can decide whether
        /// to offer "Paste Recipe Text" (see `canPasteText`) — mirrors
        /// `FailedJob.errorCode`/`canPasteText` for the persistent list card.
        let errorCode: String?

        /// Whether this failure can be recovered by pasting the recipe text.
        var canPasteText: Bool { RecipeProviderError.canPasteText(code: errorCode) }
    }

    private let provider: RecipeProvider
    private let store: PendingJobStore
    /// On-device cache of completed recipes so the list survives full relaunches
    /// (the backend has no vault endpoint). Written in `handleComplete`.
    private let recipeStore: RecipeStore
    /// Job ids with an in-flight poll task, keyed to when that poll started —
    /// so `reconcile()`/`submit()` never start a second poll for a job whose
    /// poll is genuinely still running. `poll()`'s per-call timeout (see
    /// `fetchJobWithTimeout`) plus its `defer` should always clear an entry on
    /// its own; `startPolling`'s `activePollStaleAfter` check is a defensive
    /// backstop so a single wedged Task can never block every future
    /// `reconcile()` for that job forever, even if that guarantee somehow
    /// doesn't hold.
    private var activePolls: [String: Date] = [:]
    /// How long an entry may sit in `activePolls` before `startPolling` treats
    /// it as stale and starts a fresh poll anyway — comfortably longer than
    /// `maxWait + perPollTimeout` could ever legitimately take. Injectable so
    /// tests can exercise this backstop without a real multi-minute wait.
    private let activePollStaleAfter: TimeInterval
    /// Job ids we've already surfaced the failure alert for this session, so the
    /// same failure never pops the alert twice. Not persisted (resets each launch).
    private var alertedJobIds: Set<String> = []
    /// Job ids the user manually removed from the pending list via
    /// `removePending` while a poll for them may still be in flight. Checked by
    /// `handleComplete`/`handleFailed` so that poll's eventual result can't
    /// resurrect a failed/complete card for a job the user already dismissed.
    /// Not persisted — a relaunch has no in-flight poll to guard against.
    private var removedJobIds: Set<String> = []
    /// Whether the one-time recipe seed has succeeded. Guards `load()` so a
    /// re-fired `.task` can never re-run it and clobber recipes resolved this
    /// session (see `load()`).
    private var hasLoaded = false

    /// Poll cadence/budget — mirrors `APIRecipeProvider.pollUntilRecipe`.
    /// Injectable so tests can drive `poll()`'s budget-expiry path (see
    /// `poll()`) without a real 120-second wait.
    private let pollInterval: Duration
    private let maxWait: Duration
    /// Hard per-call bound on a single `fetchJob`, independent of whatever
    /// timeout (if any) the transport enforces. Without this, one hung network
    /// call blocks the await forever, so `poll()`'s own `while clock.now <
    /// deadline` check never gets a chance to re-run — the loop doesn't just
    /// miss the budget, it never even reaches the check. This is what actually
    /// happened with a stuck gimmesomeoven.com import: server logs showed
    /// exactly one poll request ever reaching the backend, then nothing for
    /// 14+ minutes despite the app demonstrably being alive and making other
    /// requests in that window — the second `fetchJob` call itself never
    /// returned, it wasn't that the app was suspended.
    private let perPollTimeout: Duration

    /// Sync hub (nil in previews/unscoped builds → no sync recording).
    private let sync: SyncCoordinator?

    /// `maxWait` as a `TimeInterval`, for comparing against a `PendingJob`'s
    /// `submittedAt` (a `Date`) — `Duration` and `Date` don't arithmetic
    /// against each other directly.
    private var maxWaitSeconds: TimeInterval {
        let c = maxWait.components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1_000_000_000_000_000_000
    }

    /// Canonical form of a submitted URL, used only to decide "is this the
    /// same link" for de-duplication/removal — never sent to the server.
    /// Deliberately conservative (trim + lowercase only, no query/scheme
    /// surgery): `AddRecipeView` doesn't trim pasted text before calling
    /// `submit(url:)`, so a paste with a trailing newline (common from Notes/
    /// clipboard) previously created a *second*, distinct-looking pending
    /// entry for what is visibly the same link — one `removePendingMatching`
    /// (exact string match) couldn't catch. This key is what makes such a
    /// pair collapse into one.
    private static func canonicalURLKey(_ url: String) -> String {
        url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    init(
        provider: RecipeProvider,
        userScope: String? = nil,
        sync: SyncCoordinator? = nil,
        store: PendingJobStore = PendingJobStore(),
        pollInterval: Duration = .seconds(1.5),
        maxWait: Duration = .seconds(120),
        perPollTimeout: Duration = .seconds(20),
        activePollStaleAfter: TimeInterval = 300
    ) {
        self.provider = provider
        self.sync = sync
        self.store = store
        self.pollInterval = pollInterval
        self.maxWait = maxWait
        self.perPollTimeout = perPollTimeout
        self.activePollStaleAfter = activePollStaleAfter
        // The recipe cache is account-scoped; the pending-jobs queue stays
        // device-local (transient, reconciled per Stage 6).
        self.recipeStore = RecipeStore(userScope: userScope)
        // Show any persisted jobs immediately (e.g. submitted last session, or by
        // the Share Extension while the app was closed) before the first re-poll.
        self.pending = store.all()
        // Seed the list from the on-device cache so recipes extracted in earlier
        // sessions are present the instant the app launches, before any network.
        self.recipes = recipeStore.all()
        // A sync pull hydrates recipe bodies straight to disk (RecipeStore) and
        // does NOT touch this in-memory list. Without this hook a recipe planned
        // on another device stays invisible until a cold relaunch re-seeds from
        // disk — which is exactly what left the Grocery List showing an empty
        // "Nothing to shop for" for a day that had a meal planned. Registering
        // here means the coordinator calls refreshFromStore() after any pull that
        // wrote new data.
        sync?.registerRefreshable(self)
    }

    /// Merge any recipes now on disk (e.g. bodies just hydrated by a sync pull)
    /// into the in-memory list, without dropping recipes resolved this session.
    /// Same merge-never-overwrite rule as `load()`: only genuinely new ids are
    /// appended, so no other consumer of `recipes` loses a session recipe and the
    /// existing ordering of already-present recipes is preserved.
    func refreshFromStore() {
        let known = Set(recipes.map(\.recipeId))
        let added = recipeStore.all().filter { !known.contains($0.recipeId) }
        guard !added.isEmpty else { return }
        recipes.append(contentsOf: added)
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
    ///
    /// Two self-healing steps run first, so a job left behind by an older
    /// build (or a duplicate submission) can never stick around forever
    /// waiting for the user to notice and manually remove it:
    ///  1. `dedupeStoreByCanonicalURL()` collapses multiple pending entries
    ///     for the same link down to the newest one.
    ///  2. Any entry already older than `maxWait` skips a fresh `startPolling`
    ///     — which would otherwise hand it a brand-new `maxWait` budget on
    ///     *every* launch, via `poll()`'s deadline being computed relative to
    ///     when that particular call starts, not the job's original
    ///     `submittedAt`. A device that gets backgrounded/killed by iOS more
    ///     often than once per `maxWait` would never let any single poll
    ///     attempt reach its own final check, so the card could persist
    ///     indefinitely across restarts even though `poll()` itself always
    ///     terminates within one run. Going straight to the single final
    ///     check (`resolveAlreadyStaleJob`) instead resolves it on this
    ///     launch no matter how many previous launches were cut short.
    func reconcile() {
        dedupeStoreByCanonicalURL()
        pending = store.all()
        pollLog.log("reconcile(): \(self.pending.count, privacy: .public) pending job(s): \(self.pending.map(\.jobId).joined(separator: ","), privacy: .public)")
        for job in pending {
            if activePolls[job.jobId] == nil, Date().timeIntervalSince(job.submittedAt) >= maxWaitSeconds {
                pollLog.warning("reconcile(\(job.jobId, privacy: .public)): already past budget (submitted \(Int(Date().timeIntervalSince(job.submittedAt)), privacy: .public)s ago) — single final check, no fresh poll loop")
                activePolls[job.jobId] = Date()
                Task { await resolveAlreadyStaleJob(jobId: job.jobId) }
            } else {
                startPolling(jobId: job.jobId)
            }
        }
    }

    /// Collapses multiple pending entries that resolve to the same
    /// `canonicalURLKey` down to the single newest one (`store.all()` returns
    /// newest-first). A duplicate can arise two ways: a URL resubmitted before
    /// the first attempt resolved, or the exact same paste producing a
    /// whitespace/case variant the two attempts didn't share verbatim (see
    /// `canonicalURLKey`). Either way, two visually-identical "Extracting
    /// recipe…" cards for what the user perceives as one import is confusing
    /// on its own, and previously meant `removePendingMatching`'s exact-string
    /// match — or the user tapping Remove on just one of them — could leave a
    /// sibling behind that looked exactly like the one just dismissed.
    private func dedupeStoreByCanonicalURL() {
        var seenKeys = Set<String>()
        var duplicateIds: [String] = []
        for job in store.all() {   // newest-first
            let key = Self.canonicalURLKey(job.url)
            if seenKeys.contains(key) {
                duplicateIds.append(job.jobId)
            } else {
                seenKeys.insert(key)
            }
        }
        guard !duplicateIds.isEmpty else { return }
        pollLog.warning("dedupeStoreByCanonicalURL(): clearing \(duplicateIds.count, privacy: .public) duplicate pending job(s): \(duplicateIds.joined(separator: ","), privacy: .public)")
        for jobId in duplicateIds {
            removedJobIds.insert(jobId)
            store.remove(jobId: jobId)
        }
    }

    /// Dismiss a failed card (removes the in-memory entry; the store no longer
    /// holds it).
    func dismissFailed(jobId: String) {
        failed.removeAll { $0.jobId == jobId }
    }

    /// Remove a still-pending (processing) job the user wants gone — no server
    /// call, purely local. The intended escape hatch for a job stuck showing
    /// "Extracting recipe…" (e.g. one whose poll ran past `maxWait` with the
    /// backend never reaching a terminal status in time, or that only resolves
    /// on the next foreground `reconcile()`, which may be a while off) with no
    /// other way to clear it. If a poll is still in flight for this job, its
    /// eventual result is discarded (see `removedJobIds`) rather than
    /// resurrecting a failed/complete card for a job already dismissed here.
    func removePending(jobId: String) {
        removedJobIds.insert(jobId)
        store.remove(jobId: jobId)
        pending = store.all()
    }

    /// Remove every still-pending job for `url` — the same escape hatch as
    /// `removePending(jobId:)`, but for a whole URL at once. A single failure
    /// alert only carries the one job id that actually failed; if a stale or
    /// duplicate entry for the same URL is also sitting in `PendingJobStore`
    /// (e.g. left over from an older build, or a second submission of the same
    /// link), dismissing the alert — Cancel or Paste Recipe Text — clears all
    /// of them, not just the one the alert was for, so the user never taps
    /// past a failure only to find a card for the same URL still spinning.
    func removePendingMatching(url: String) {
        let key = Self.canonicalURLKey(url)
        for job in pending where Self.canonicalURLKey(job.url) == key {
            removedJobIds.insert(job.jobId)
            store.remove(jobId: job.jobId)
        }
        pending = store.all()
    }

    /// Delete a finished recipe from the user's library. Mirrors the inverse of
    /// `handleComplete`: drop it from the in-memory list, remove the on-device
    /// body cache, and record a `.library` tombstone so the deletion propagates
    /// to the user's other devices (the same `deleted: true` shape
    /// `LocalSyncApplier.applyLibrary` consumes to `recipeStore.remove` on a pull).
    ///
    /// Cookbook membership is per-recipe and lives in a separate store/collection,
    /// so it's cleared by the caller via `CookbooksModel.removeRecipeFromAllCookbooks`
    /// — kept out of here to avoid coupling this model to CookbooksModel.
    func deleteRecipe(_ recipe: Recipe) {
        recipes.removeAll { $0.recipeId == recipe.recipeId }
        recipeStore.remove(recipeId: recipe.recipeId)
        sync?.record(.library, itemId: recipe.recipeId, payload: nil, deleted: true)
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
        if let startedAt = activePolls[jobId] {
            let age = Date().timeIntervalSince(startedAt)
            guard age > activePollStaleAfter else {
                pollLog.log("startPolling(\(jobId, privacy: .public)): already active (\(Int(age), privacy: .public)s) — skipping")
                return
            }
            pollLog.warning("startPolling(\(jobId, privacy: .public)): existing poll stale after \(Int(age), privacy: .public)s — starting a fresh one")
        } else {
            pollLog.log("startPolling(\(jobId, privacy: .public)): starting")
        }
        activePolls[jobId] = Date()
        Task { await poll(jobId: jobId) }
    }

    /// Wraps a single `provider.fetchJob` call with `perPollTimeout`, so a hung
    /// network call can never block `poll()`'s loop from re-checking its own
    /// budget (see `perPollTimeout`'s doc comment). Races the real call against
    /// a timer; whichever finishes first wins, and the loser is cancelled.
    private func fetchJobWithTimeout(jobId: String) async throws -> JobEnvelope {
        let provider = self.provider   // snapshot: child tasks below are non-isolated
        let timeout = perPollTimeout
        return try await withThrowingTaskGroup(of: JobEnvelope.self) { group in
            group.addTask { try await provider.fetchJob(jobId: jobId) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw RecipeProviderError.timedOut
            }
            guard let first = try await group.next() else {
                throw RecipeProviderError.timedOut
            }
            group.cancelAll()
            return first
        }
    }

    private func poll(jobId: String) async {
        defer {
            activePolls.removeValue(forKey: jobId)
            pollLog.log("poll(\(jobId, privacy: .public)): exited, activePolls cleared")
        }
        pollLog.log("poll(\(jobId, privacy: .public)): started")
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: maxWait)

        while clock.now < deadline {
            if Task.isCancelled {
                pollLog.warning("poll(\(jobId, privacy: .public)): task cancelled — stopping early")
                break
            }
            do {
                let envelope = try await fetchJobWithTimeout(jobId: jobId)
                pollLog.log("poll(\(jobId, privacy: .public)): status=\(envelope.job.status.rawValue, privacy: .public)")
                if envelope.job.status == .queued || envelope.job.status == .processing {
                    store.updateStatus(jobId: jobId, envelope.job.status)
                    pending = store.all()
                }
                if handleIfTerminal(jobId: jobId, envelope: envelope) { return }
            } catch RecipeProviderError.httpStatus(404) {
                // Job genuinely not on the server — terminal; clean it up.
                pollLog.warning("poll(\(jobId, privacy: .public)): 404 — job gone server-side")
                handleFailed(jobId: jobId, message: RecipeProviderError.httpStatus(404).userMessage)
                return
            } catch {
                // Transient (offline / a single call timing out per
                // `fetchJobWithTimeout` / 5xx): keep the card and retry on the
                // next tick — the outer `deadline` check above (now always
                // reachable within `perPollTimeout`, never blocked on a single
                // hung call) is what ultimately bounds this.
                pollLog.log("poll(\(jobId, privacy: .public)): transient error, retrying — \(String(describing: error), privacy: .public)")
            }
            try? await Task.sleep(for: pollInterval)
        }

        // Budget exhausted. No path out of this function may leave the job
        // still pending: do one final check rather than silently giving up —
        // a job that only reaches a terminal status on the server *after*
        // `maxWait` would otherwise leave an "Extracting recipe…" card stuck
        // forever, since nothing but a fresh foreground `reconcile()` used to
        // re-arm it.
        pollLog.warning("poll(\(jobId, privacy: .public)): budget exhausted — final check")
        await performFinalCheckAndResolve(jobId: jobId)
    }

    /// One `fetchJob` call, terminal or not: a terminal result is handled
    /// normally; anything else (still processing, offline, the call itself
    /// timing out) is converted to a local `client_timeout` failure. Shared by
    /// `poll()`'s post-budget tail and `resolveAlreadyStaleJob` (a job whose
    /// budget was already spent across a previous, cut-short launch) so both
    /// resolve a stuck job the exact same way.
    private func performFinalCheckAndResolve(jobId: String) async {
        do {
            let envelope = try await fetchJobWithTimeout(jobId: jobId)
            if handleIfTerminal(jobId: jobId, envelope: envelope) {
                pollLog.log("finalCheck(\(jobId, privacy: .public)): found a terminal status")
                return
            }
        } catch {
            // Whatever the reason (offline, 5xx, the final call itself timing
            // out, decode error, ...) — the user has already waited the full
            // budget either way; fall through to the same local timeout below.
            pollLog.warning("finalCheck(\(jobId, privacy: .public)): failed — \(String(describing: error), privacy: .public)")
        }
        // Still not terminal (or the final check itself failed): convert to a
        // local, paste-eligible failure so the card always clears and the user
        // always gets a way forward, never an indefinite spinner.
        pollLog.warning("finalCheck(\(jobId, privacy: .public)): converting to local client_timeout failure")
        handleFailed(
            jobId: jobId,
            message: RecipeProviderError.jobFailed(code: RecipeProviderError.clientTimeoutCode, message: nil).userMessage,
            code: RecipeProviderError.clientTimeoutCode
        )
    }

    /// `reconcile()`'s path for a pending entry whose `maxWait` budget is
    /// already spent (it was submitted long enough ago, across a previous
    /// launch, that a fresh poll loop would just be re-granting it a budget it
    /// already used). Does exactly one `fetchJob` call via
    /// `performFinalCheckAndResolve` instead of `poll()`'s full
    /// `pollInterval`-spaced loop, so this launch resolves it immediately
    /// rather than needing another full `maxWait` of uptime it may never get.
    private func resolveAlreadyStaleJob(jobId: String) async {
        defer {
            activePolls.removeValue(forKey: jobId)
            pollLog.log("resolveAlreadyStaleJob(\(jobId, privacy: .public)): exited, activePolls cleared")
        }
        await performFinalCheckAndResolve(jobId: jobId)
    }

    /// Handles a terminal envelope exactly like the poll loop's inline switch
    /// used to (factored out so the post-budget final check in `poll()` can
    /// share it). Returns `true` when `status` was terminal (caller should
    /// stop polling), `false` when still queued/processing.
    @discardableResult
    private func handleIfTerminal(jobId: String, envelope: JobEnvelope) -> Bool {
        switch envelope.job.status {
        case .queued, .processing:
            return false
        case .complete:
            handleComplete(jobId: jobId, envelope: envelope)
            return true
        case .failed:
            let message = RecipeProviderError
                .jobFailed(code: envelope.job.errorCode, message: envelope.job.error)
                .userMessage
            handleFailed(jobId: jobId, message: message, url: envelope.job.url,
                         code: envelope.job.errorCode)
            return true
        }
    }

    private func handleComplete(jobId: String, envelope: JobEnvelope) {
        guard !removedJobIds.contains(jobId) else { return }
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
        guard !removedJobIds.contains(jobId) else { return }
        let jobURL = url ?? pending.first(where: { $0.jobId == jobId })?.url ?? ""
        // Clear the processing card the instant a job reaches `.failed` — this
        // does not depend on the alert below, or on the user ever seeing or
        // dismissing it. Every error code takes this same path, so a job never
        // stays a "processing" card once the backend has terminally failed it.
        store.remove(jobId: jobId)
        pending = store.all()

        if !failed.contains(where: { $0.jobId == jobId }) {
            failed.append(FailedJob(jobId: jobId, url: jobURL, message: message, errorCode: code))
        }
        // Surface a one-time alert on the transition to failed. Once per jobId
        // per session; a second concurrent failure keeps its card but doesn't
        // stomp an unacknowledged alert.
        if !alertedJobIds.contains(jobId) {
            alertedJobIds.insert(jobId)
            if failureAlert == nil {
                failureAlert = FailureAlert(id: jobId, message: message, errorCode: code)
            }
        }
    }
}
