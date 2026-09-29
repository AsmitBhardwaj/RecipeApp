//
//  OnboardingFlow.swift
//  RecipeKit
//
//  Pure routing for first-run: launch → Value → Sign in → quiz → main app.
//  The Value screen stores nothing about the user; only a device-level "seen"
//  flag (there is no account yet when it shows) so a later sign-out / sign-in
//  never replays it. Kept free of SwiftUI so the ordering rules are unit-testable.
//

import Foundation

public enum LaunchRoute: Equatable, Sendable {
    /// Signed out, Value screen not seen yet on this device.
    case value
    /// Signed out, Value screen already seen (or skipped).
    case signIn
    /// Signed in, quiz answers still owed.
    case quiz
    /// Signed in and onboarded (or the quiz was skipped on the Value screen).
    case main
}

public enum OnboardingRouter {
    /// - Parameters:
    ///   - hasSeenValue: device-level flag set when Value's Continue/Skip is tapped
    ///     (and for any signed-in user, so returning users never see it).
    ///   - skippedQuiz: Value's Skip was tapped; answers stay unset and the setup
    ///     flow runs later in Plan on a Budget.
    public static func route(
        isSignedIn: Bool,
        hasSeenValue: Bool,
        hasCompletedOnboarding: Bool,
        skippedQuiz: Bool
    ) -> LaunchRoute {
        if isSignedIn {
            return (hasCompletedOnboarding || skippedQuiz) ? .main : .quiz
        }
        return hasSeenValue ? .signIn : .value
    }
}

/// Device-level onboarding flags (App Group defaults, injectable for tests).
public struct OnboardingFlowStore {
    private static let seenKey = "onboarding_value_seen_v1"
    private static let skippedKey = "onboarding_quiz_skipped_v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = UserDefaults(suiteName: AppGroup.identifier) ?? .standard) {
        self.defaults = defaults
    }

    public var hasSeenValue: Bool { defaults.bool(forKey: Self.seenKey) }
    public var skippedQuiz: Bool { defaults.bool(forKey: Self.skippedKey) }

    /// Value's Continue (`skipped: false`) or Skip (`skipped: true`).
    public func markValueSeen(skipped: Bool = false) {
        defaults.set(true, forKey: Self.seenKey)
        if skipped { defaults.set(true, forKey: Self.skippedKey) }
    }

    /// The skip was honoured after sign-in (onboarding completed without answers).
    public func clearSkip() {
        defaults.removeObject(forKey: Self.skippedKey)
    }
}
