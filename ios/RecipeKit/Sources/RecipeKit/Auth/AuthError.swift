//
//  AuthError.swift
//  RecipeKit
//
//  Typed failures for the auth flow, so the UI can show a specific message
//  ("that email is taken", "too many attempts") rather than a generic error.
//

import Foundation

public enum AuthError: Error, Equatable, Sendable {
    case invalidCredentials       // 401 — wrong email/password or bad token
    case emailInUse               // 409 — registration with an existing email
    case rateLimited              // 429 — too many attempts
    case notConfigured(String)    // client-side: provider not set up (e.g. Google)
    case cancelled                // user dismissed a provider sheet
    case offline
    case timedOut
    case server(Int)              // other non-2xx
    case invalidResponse(String)

    public var userMessage: String {
        switch self {
        case .invalidCredentials: return "Incorrect email or password."
        case .emailInUse: return "That email already has an account. Try signing in."
        case .rateLimited: return "Too many attempts. Please wait a moment and try again."
        case .notConfigured(let what): return "\(what) sign-in isn’t available in this build."
        case .cancelled: return "Sign-in was cancelled."
        case .offline: return "You’re offline. Check your connection and try again."
        case .timedOut: return "The request timed out. Please try again."
        case .server: return "Something went wrong on our end. Please try again."
        case .invalidResponse: return "Unexpected response from the server."
        }
    }
}
