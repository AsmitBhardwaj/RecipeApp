//
//  APIRecipeProvider.swift
//  RecipeKit
//
//  Real `RecipeProvider` conformance talking to the live backend over HTTPS:
//    POST /v1/jobs            -> enqueue a job for a URL, returns a JobEnvelope
//    GET  /v1/jobs/{job_id}   -> poll a job, returns a JobEnvelope
//
//  Both endpoints return `{ "job": Job, "recipe": Recipe? }`; the recipe is null
//  until the job reaches `complete`. `submitRecipe(url:)` enqueues then polls to
//  a terminal state so callers can just `await` a finished `Recipe`.
//
//  Every request carries two abuse-prevention headers:
//    * `X-User-Id: RecipeKit.currentUserID` — the anonymous per-device UUID the
//      backend now rate-limits on (spoofable, so a deterrence signal, not auth).
//    * `X-App-Key: AppConfig.appKey` — a static shared secret the backend
//      requires on every request (401 otherwise). Sent only when configured for
//      this build; see AppConfig for why this is deterrence, not real auth.
//

import Foundation

public struct APIRecipeProvider: RecipeProvider {

    /// The live backend. Overridable for tests / staging.
    public static let defaultBaseURL = URL(string: "https://recipeapp-production-3a60.up.railway.app")!

    let baseURL: URL
    let session: URLSession
    /// How the provider resolves the anonymous user id per request. Injectable so
    /// tests don't touch the real Keychain.
    let userID: () -> String
    /// How the provider resolves the shared app key per request. Injectable for
    /// tests; defaults to the build-time value in the app bundle.
    let appKey: () -> String
    /// Poll cadence and total budget for `submitRecipe`.
    let pollInterval: Duration
    let maxWait: Duration

    public init(
        baseURL: URL = APIRecipeProvider.defaultBaseURL,
        session: URLSession = .shared,
        userID: @escaping () -> String = { RecipeKit.currentUserID },
        appKey: @escaping () -> String = { AppConfig.appKey },
        pollInterval: Duration = .seconds(1.5),
        maxWait: Duration = .seconds(120)
    ) {
        self.baseURL = baseURL
        self.session = session
        self.userID = userID
        self.appKey = appKey
        self.pollInterval = pollInterval
        self.maxWait = maxWait
    }

    // MARK: - RecipeProvider

    /// No backend "list my vault" endpoint exists yet, so there is nothing to
    /// fetch. Returns empty; the app accumulates extracted recipes in-session.
    public func fetchRecipes() async throws -> [Recipe] {
        []
    }

    /// Enqueue a URL and poll to completion, returning the finished recipe.
    public func submitRecipe(url: String) async throws -> Recipe {
        let submitted = try await submitJob(url: url)
        // POST may already come back terminal in edge cases; handle immediately.
        if let recipe = try recipe(from: JobEnvelope(job: submitted, recipe: nil), allowNilWhenPending: true) {
            return recipe
        }
        return try await pollUntilRecipe(jobId: submitted.jobId)
    }

    // MARK: - Job-level API (job_id / status the UI can track)

    /// POST /v1/jobs — enqueue a job for the given URL. Returns the created `Job`
    /// (status `queued`), whose `jobId` can be polled.
    public func submitJob(url: String) async throws -> Job {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, URL(string: trimmed) != nil else {
            throw RecipeProviderError.invalidURL
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/jobs"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyCommonHeaders(&request)
        request.httpBody = try JSONEncoder().encode(JobRequestBody(url: trimmed))

        let envelope: JobEnvelope = try await send(request)
        return envelope.job
    }

    /// GET /v1/jobs/{job_id} — one poll. Returns the current envelope.
    public func fetchJob(jobId: String) async throws -> JobEnvelope {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/jobs/\(jobId)"))
        applyCommonHeaders(&request)
        return try await send(request)
    }

    /// POST /v1/jobs/{job_id}/paste — retry the job with pasted recipe text.
    /// Runs synchronously server-side and returns the terminal envelope, so a
    /// `complete` job already carries its recipe.
    public func submitPastedText(jobId: String, text: String) async throws -> JobEnvelope {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RecipeProviderError.invalidResponse("no text to submit")
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/jobs/\(jobId)/paste"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyCommonHeaders(&request)
        request.httpBody = try JSONEncoder().encode(PasteRequestBody(text: trimmed))
        return try await send(request)
    }

    // MARK: - Feedback

    /// POST /feedback — send user feedback (a rating and/or a message, plus an
    /// optional contact email). Carries the same abuse-prevention headers as the
    /// job endpoints (X-User-Id / X-App-Key). Throws on network/HTTP failure.
    public func submitFeedback(
        rating: Int?,
        message: String?,
        contactEmail: String?,
        appVersion: String?,
        platform: String = "ios"
    ) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("feedback"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyCommonHeaders(&request)
        request.httpBody = try JSONEncoder().encode(
            FeedbackBody(
                rating: rating,
                message: message,
                contactEmail: contactEmail,
                appVersion: appVersion,
                platform: platform
            )
        )
        let _: FeedbackAck = try await send(request)
    }

    // MARK: - Polling

    private func pollUntilRecipe(jobId: String) async throws -> Recipe {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: maxWait)

        while clock.now < deadline {
            try? await Task.sleep(for: pollInterval)
            let envelope = try await fetchJob(jobId: jobId)
            if let recipe = try recipe(from: envelope, allowNilWhenPending: true) {
                return recipe
            }
            // else still queued/processing — keep polling.
        }
        throw RecipeProviderError.timedOut
    }

    /// Interprets a terminal envelope. Returns the recipe on `complete`, throws on
    /// `failed`, and returns nil while still pending (so the poller keeps going).
    private func recipe(from envelope: JobEnvelope, allowNilWhenPending: Bool) throws -> Recipe? {
        switch envelope.job.status {
        case .complete:
            guard let recipe = envelope.recipe else {
                throw RecipeProviderError.invalidResponse("job completed but carried no recipe")
            }
            return recipe
        case .failed:
            throw RecipeProviderError.jobFailed(code: envelope.job.errorCode, message: envelope.job.error)
        case .queued, .processing:
            if allowNilWhenPending { return nil }
            throw RecipeProviderError.invalidResponse("job not terminal")
        }
    }

    // MARK: - Transport

    private func applyCommonHeaders(_ request: inout URLRequest) {
        request.setValue(userID(), forHTTPHeaderField: "X-User-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Only attach the app key when this build actually has one — an empty
        // header would just be a wrong key. Dev builds without Secrets.xcconfig
        // send no key (and a backend without APP_KEY configured accepts them).
        let key = appKey()
        if !key.isEmpty {
            request.setValue(key, forHTTPHeaderField: "X-App-Key")
        }
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            switch urlError.code {
            case .notConnectedToInternet, .dataNotAllowed:
                throw RecipeProviderError.offline
            case .timedOut:
                throw RecipeProviderError.timedOut
            default:
                throw RecipeProviderError.network(urlError.localizedDescription)
            }
        }

        guard let http = response as? HTTPURLResponse else {
            throw RecipeProviderError.invalidResponse("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RecipeProviderError.httpStatus(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw RecipeProviderError.invalidResponse("could not decode response: \(error)")
        }
    }
}

// MARK: - Request body

private struct JobRequestBody: Encodable {
    let url: String
}

private struct PasteRequestBody: Encodable {
    let text: String
}

private struct FeedbackBody: Encodable {
    let rating: Int?
    let message: String?
    let contactEmail: String?
    let appVersion: String?
    let platform: String

    enum CodingKeys: String, CodingKey {
        case rating, message, platform
        case contactEmail = "contact_email"
        case appVersion = "app_version"
    }
}

private struct FeedbackAck: Decodable {
    let status: String
}
