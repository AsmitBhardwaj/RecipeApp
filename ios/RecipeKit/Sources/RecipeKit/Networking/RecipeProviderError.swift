//
//  RecipeProviderError.swift
//  RecipeKit
//
//  Typed failure states a `RecipeProvider` can surface, each mapping to a
//  distinct thing the UI can show — never a crash or a silent failure.
//

import Foundation

public enum RecipeProviderError: Error, Equatable {
    /// The device has no usable network connection (offline / airplane mode).
    case offline
    /// The request exceeded its time budget (slow network, or the job never
    /// reached a terminal state within the poll cap).
    case timedOut
    /// A non-2xx HTTP response. `status` is the code (e.g. 429 rate-limited,
    /// 404 job not found, 5xx server error).
    case httpStatus(Int)
    /// A transport-level error other than offline/timeout (DNS, TLS, etc.).
    case network(String)
    /// The backend marked the job failed. `code` is the stable machine string
    /// (e.g. "caption_not_found", "fetch_failed"); `message` is human-readable.
    case jobFailed(code: String?, message: String?)
    /// The URL passed in was empty or not a valid URL.
    case invalidURL
    /// The response wasn't shaped as expected (decoding failed, or a completed
    /// job carried no recipe).
    case invalidResponse(String)

    /// A short, user-facing message suitable for an alert or error state.
    public var userMessage: String {
        switch self {
        case .offline:
            return "You appear to be offline. Check your connection and try again."
        case .timedOut:
            return "This is taking longer than expected. Please try again in a moment."
        case .httpStatus(let code):
            if code == 429 { return "You're doing that too fast — please wait a minute and try again." }
            if code == 404 { return "We couldn't find that job on the server." }
            return "The server returned an error (\(code)). Please try again."
        case .network:
            return "Couldn't reach the server. Check your connection and try again."
        case .jobFailed(_, let message):
            return message ?? "We couldn't read a recipe from that link."
        case .invalidURL:
            return "That doesn't look like a valid link. Paste an Instagram, TikTok, or recipe-website URL."
        case .invalidResponse:
            return "We got an unexpected response from the server. Please try again."
        }
    }
}
