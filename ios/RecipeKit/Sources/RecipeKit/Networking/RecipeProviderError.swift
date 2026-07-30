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
            if code == 404 { return "We lost track of this one — try adding it again." }
            return "The server returned an error (\(code)). Please try again."
        case .network:
            return "Couldn't reach the server. Check your connection and try again."
        case .jobFailed(let code, let message):
            return Self.failedJobMessage(code: code, backendMessage: message)
        case .invalidURL:
            return "That doesn't look like a valid link. Paste an Instagram, TikTok, or recipe-website URL."
        case .invalidResponse:
            return "We got an unexpected response from the server. Please try again."
        }
    }

    /// Maps a backend job-failure `error_code` to a distinct, honest message.
    /// Falls back to the backend's own message (then a generic line) for codes
    /// we don't recognize, so a new server code never shows blank.
    private static func failedJobMessage(code: String?, backendMessage: String?) -> String {
        switch code {
        case "no_recipe_found":
            return "We couldn't find a recipe on this page."
        case "fetch_failed", "too_many_redirects":
            return "We couldn't reach that page. Check the link and try again."
        case "not_html":
            return "That link doesn't point to a readable web page."
        case "too_large":
            return "That page was too large for us to read."
        case "dns_error":
            return "We couldn't find that website."
        case "blocked_host", "blocked_scheme":
            return "That link points somewhere we can't open."
        case "invalid_url":
            return "That doesn't look like a link we can read."
        case "caption_not_found":
            return "This post doesn't have a caption we can read a recipe from."
        case "private_video":
            return "That video is private, so we can't read it."
        case "video_unavailable":
            return "That video isn't available anymore."
        case "login_required":
            return "That video needs a login to view, so we can't read it."
        case "unsupported_url":
            return "We don't support that link yet."
        case "could_not_identify_dish":
            return "We couldn't tell what dish this caption is about."
        case "missing_api_key", "llm_api_error", "invalid_llm_output":
            return "Something went wrong on our end. Please try again."
        case "llm_refusal":
            return "We couldn't read a recipe from this one."
        default:
            return backendMessage ?? "We couldn't read a recipe from that link."
        }
    }
}
