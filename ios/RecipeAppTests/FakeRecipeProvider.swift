//
//  FakeRecipeProvider.swift
//  RecipeAppTests
//
//  A `RecipeProvider` test double whose `fetchJob` resolves to a configured
//  terminal status on the very first poll — so `PendingJobsModel`'s async
//  polling `Task` (started inside `submit(url:)`) settles almost immediately,
//  letting tests await a specific outcome without a real network round trip.
//

import Foundation
import RecipeKit

final class FakeRecipeProvider: RecipeProvider {
    /// When set, `fetchJob` resolves as a failed job with this error code.
    /// When nil, `fetchJob` resolves as `.complete` (unused by the failure
    /// tests, but keeps the double honest about every terminal outcome).
    var failureCode: String?
    var failureMessage: String = "We couldn't read a recipe from that link."

    private static func iso(_ date: Date = Date()) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    func fetchRecipes() async throws -> [Recipe] { [] }

    func submitRecipe(url: String) async throws -> Recipe {
        fatalError("not exercised by PendingJobsModelTests")
    }

    func submitJob(url: String) async throws -> Job {
        Job(jobId: "job-under-test", userId: "test-user", url: url, status: .queued, createdAt: Self.iso())
    }

    func fetchJob(jobId: String) async throws -> JobEnvelope {
        let job = Job(
            jobId: jobId,
            userId: "test-user",
            url: "https://example.com",
            status: .failed,
            createdAt: Self.iso(),
            errorCode: failureCode,
            error: failureMessage
        )
        return JobEnvelope(job: job, recipe: nil)
    }

    func submitPastedText(jobId: String, text: String) async throws -> JobEnvelope {
        fatalError("not exercised by PendingJobsModelTests")
    }
}
