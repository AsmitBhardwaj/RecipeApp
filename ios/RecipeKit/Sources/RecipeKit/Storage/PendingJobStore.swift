//
//  PendingJobStore.swift
//  RecipeKit
//
//  Durable, cross-process store of in-flight jobs, backed by the App Group's
//  shared `UserDefaults(suiteName:)`. Both the main app and the (future) Share
//  Extension construct the same store and see the same pending jobs, so a job
//  enqueued from the share sheet shows up as a processing card in the app, and a
//  job submitted in the app survives a force-quit.
//
//  Why UserDefaults and not a coordinated file: RecipeKit already models
//  everything as `Codable`, and a single JSON-encoded array under one key is the
//  lightest thing consistent with that. The app and the extension realistically
//  never write in the same instant; writes are read-modify-write keyed by
//  `jobId`, so sequential writes from either process merge cleanly. If true
//  simultaneous-write races ever matter, this type is the single seam to swap
//  for an `NSFileCoordinator`-backed file — callers won't change.
//

import Foundation

public struct PendingJobStore {

    /// Single key holding the JSON-encoded `[PendingJob]`.
    private static let storageKey = "pending_jobs_v1"

    private let defaults: UserDefaults

    /// Production initializer: the shared App Group suite. If the suite can't be
    /// opened (a real entitlement misconfiguration) we fall back to `.standard`
    /// so the app degrades to app-local tracking rather than crashing — the
    /// pending cards still work, they just won't be shared with the extension.
    public init(suiteName: String = AppGroup.identifier) {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    /// Test/seam initializer: inject any `UserDefaults` (e.g. an ephemeral suite)
    /// so host tests never touch the real shared container.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    // MARK: - Reads

    /// All pending jobs, newest submission first.
    public func all() -> [PendingJob] {
        guard let data = defaults.data(forKey: Self.storageKey) else { return [] }
        let jobs = (try? JSONDecoder().decode([PendingJob].self, from: data)) ?? []
        return jobs.sorted { $0.submittedAt > $1.submittedAt }
    }

    // MARK: - Writes (read-modify-write, keyed by jobId)

    /// Insert a new job or replace an existing one with the same `jobId`.
    public func upsert(_ job: PendingJob) {
        var jobs = all()
        if let idx = jobs.firstIndex(where: { $0.jobId == job.jobId }) {
            jobs[idx] = job
        } else {
            jobs.append(job)
        }
        write(jobs)
    }

    /// Update just the last-known status of a job, if present.
    public func updateStatus(jobId: String, _ status: JobStatus) {
        var jobs = all()
        guard let idx = jobs.firstIndex(where: { $0.jobId == jobId }) else { return }
        jobs[idx].lastStatus = status
        write(jobs)
    }

    /// Remove a job (e.g. once it completes, fails, or the user dismisses it).
    public func remove(jobId: String) {
        let jobs = all().filter { $0.jobId != jobId }
        write(jobs)
    }

    private func write(_ jobs: [PendingJob]) {
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
