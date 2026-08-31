//
//  PendingJob.swift
//  RecipeKit
//
//  A job the client has submitted but not yet resolved to a finished recipe.
//  Persisted in the shared App Group store (see `PendingJobStore`) so that both
//  the main app and the (future) Share Extension see the same in-flight jobs,
//  and so a job survives the app being backgrounded or force-quit mid-poll.
//
//  This is intentionally the *minimum* the client needs to resurrect a poll and
//  render a processing card: which job, for what URL, when, and its last known
//  status. The authoritative record still lives on the backend and is re-fetched
//  via `GET /v1/jobs/{job_id}` — this is only a durable pointer to it.
//

import Foundation

public struct PendingJob: Codable, Identifiable, Hashable {
    /// Backend job id — the idempotency/poll key and this entry's identity.
    public let jobId: String
    /// The URL the user shared, kept so the processing card can show context and
    /// a retry is possible without re-deriving it.
    public let url: String
    /// When the client enqueued the job. Drives card ordering (newest first) and
    /// lets the UI show elapsed time.
    public let submittedAt: Date
    /// Last status observed from the backend. Starts `.queued`/`.processing`;
    /// terminal statuses are not persisted here (the entry is removed once a job
    /// completes or fails), but the field is stored so a relaunch renders the
    /// right card before the first re-poll returns.
    public var lastStatus: JobStatus

    public var id: String { jobId }

    /// Which platform the shared URL points at, derived from its host. Mirrors the
    /// backend's classification in `urls.py` (tiktok.com → tiktok, instagram.com /
    /// instagr.am → instagram, everything else → web) so the processing card can
    /// show a source icon at queue time, before the backend has resolved the job.
    public var platform: SharePlatform { SharePlatform(url: url) }

    public init(
        jobId: String,
        url: String,
        submittedAt: Date = Date(),
        lastStatus: JobStatus = .queued
    ) {
        self.jobId = jobId
        self.url = url
        self.submittedAt = submittedAt
        self.lastStatus = lastStatus
    }
}
