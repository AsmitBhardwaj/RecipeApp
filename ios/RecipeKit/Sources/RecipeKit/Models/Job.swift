//
//  Job.swift
//  RecipeKit
//
//  Swift mirror of the backend `Job` (app/models.py) and the `JobResponse`
//  envelope returned by both POST /v1/jobs and GET /v1/jobs/{job_id}
//  (app/main.py): `{ "job": Job, "recipe": Recipe? }`.
//
//  The recipe is null while the job is queued/processing and populated once the
//  status reaches `complete`.
//

import Foundation

// MARK: - JobStatus

/// Backend `status` (Literal["queued","processing","complete","failed"]).
/// Decodes an unknown string to `.processing` rather than throwing, so a future
/// backend status can't crash decoding. `.complete`/`.failed` are terminal.
public enum JobStatus: String, Codable, Hashable {
    case queued
    case processing
    case complete
    case failed

    public var isTerminal: Bool { self == .complete || self == .failed }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = JobStatus(rawValue: raw) ?? .processing
    }
}

// MARK: - Job

/// Mirror of backend `Job` (app/models.py §4).
public struct Job: Codable, Identifiable, Hashable {
    public let jobId: String
    public let userId: String
    public let url: String
    public let canonicalVideoId: String?
    public let platform: String?
    public let status: JobStatus
    public let extractionMethod: String
    public let createdAt: String
    public let recipeId: String?
    /// Stable machine-readable failure code (e.g. "caption_not_found",
    /// "fetch_failed") when `status == .failed`.
    public let errorCode: String?
    /// Human-readable failure detail when `status == .failed`.
    public let error: String?

    public var id: String { jobId }

    public init(
        jobId: String,
        userId: String,
        url: String,
        canonicalVideoId: String? = nil,
        platform: String? = nil,
        status: JobStatus,
        extractionMethod: String = "caption_only",
        createdAt: String,
        recipeId: String? = nil,
        errorCode: String? = nil,
        error: String? = nil
    ) {
        self.jobId = jobId
        self.userId = userId
        self.url = url
        self.canonicalVideoId = canonicalVideoId
        self.platform = platform
        self.status = status
        self.extractionMethod = extractionMethod
        self.createdAt = createdAt
        self.recipeId = recipeId
        self.errorCode = errorCode
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case userId = "user_id"
        case url
        case canonicalVideoId = "canonical_video_id"
        case platform
        case status
        case extractionMethod = "extraction_method"
        case createdAt = "created_at"
        case recipeId = "recipe_id"
        case errorCode = "error_code"
        case error
    }
}

// MARK: - JobEnvelope

/// The `JobResponse` envelope from the API: the job plus its recipe (once ready).
public struct JobEnvelope: Codable, Hashable {
    public let job: Job
    public let recipe: Recipe?

    public init(job: Job, recipe: Recipe?) {
        self.job = job
        self.recipe = recipe
    }
}
