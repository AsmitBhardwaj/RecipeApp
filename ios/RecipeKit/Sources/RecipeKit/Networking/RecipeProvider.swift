//
//  RecipeProvider.swift
//  RecipeKit
//
//  The single seam between the UI and its data source. Moved here from the app
//  target so the real `APIRecipeProvider` (and the future Share Extension) share
//  one contract with the app.
//
//  Views never construct or fetch recipes directly — they go through a
//  `RecipeProvider`. The two conformances are `APIRecipeProvider` (real
//  networking, the live default) and `MockRecipeProvider` (samples, for
//  previews/testing).
//

import Foundation

public protocol RecipeProvider {
    /// The user's saved recipes for the list screen.
    ///
    /// NOTE: the current backend has no "list my vault" endpoint — it is
    /// job-oriented (submit a URL, poll, get one recipe). `APIRecipeProvider`
    /// therefore returns an empty list here and the app accumulates recipes as
    /// the user extracts them this session. `MockRecipeProvider` returns samples.
    func fetchRecipes() async throws -> [Recipe]

    /// Submit a video URL and return the finished recipe. Enqueues the job on the
    /// backend and polls until it reaches a terminal state, so the caller can
    /// simply `await` a `Recipe` (or catch a `RecipeProviderError`). Throwing
    /// `RecipeProviderError` lets the UI show a specific failure state.
    ///
    /// Convenience path — good for a fully synchronous "submit and wait" caller.
    /// UI that wants to show a durable processing card should instead use the
    /// job-level pair below (`submitJob` + `fetchJob`), which expose the
    /// `job_id` immediately instead of hiding it inside a blocking poll.
    func submitRecipe(url: String) async throws -> Recipe

    /// Enqueue a job for `url` and return the created `Job` (status `queued`)
    /// immediately, exposing its `jobId` so the caller can persist and poll it
    /// itself. This is the "submit and close" primitive the Share Extension and
    /// the processing-card flow build on.
    func submitJob(url: String) async throws -> Job

    /// Poll a single job by id, returning the current `{ job, recipe? }` envelope.
    /// The recipe is nil until the job reaches `complete`.
    func fetchJob(jobId: String) async throws -> JobEnvelope

    /// Retry a failed job with user-pasted recipe text. The remedy for failures
    /// where we couldn't obtain/read the source (e.g. `site_blocked`,
    /// `caption_not_found`): the user pastes the text and the backend re-runs
    /// extraction on it in place, returning the finished `{ job, recipe? }`.
    func submitPastedText(jobId: String, text: String) async throws -> JobEnvelope
}
