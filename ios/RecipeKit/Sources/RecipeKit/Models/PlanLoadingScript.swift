//
//  PlanLoadingScript.swift
//  RecipeKit
//
//  Pure logic behind the "Building your week…" loading screen and the Platter Pro
//  teaser: the answer lines built from the user's quiz answers, the minimum
//  display time, and the rules for WHEN the teaser is shown. Kept free of SwiftUI
//  so all of it is unit-testable.
//

import Foundation

public enum PlanLoadingScript {
    /// One line per answer the user gave, in quiz order. Unanswered / not-worth-
    /// stating answers (no moods, no appliances, "Other" store) are omitted, so a
    /// user who skipped the quiz just sees fewer lines.
    public static func answerLines(for prefs: CookingPreferences) -> [String] {
        var lines: [String] = []

        lines.append(prefs.householdSize == 1 ? "1 person" : "\(prefs.householdSize) people")

        let diets = DietaryPreference.allCases.filter(prefs.dietaryPreferences.contains)
        if diets.isEmpty || diets.contains(.noRestrictions) {
            lines.append(DietaryPreference.noRestrictions.displayName)
        } else {
            lines.append(diets.map(\.displayName).joined(separator: ", "))
        }

        let moods = prefs.orderedFoodMoods.map(\.title)
        if !moods.isEmpty { lines.append(moods.joined(separator: " · ")) }

        let tools = prefs.orderedAppliances.map(\.title)
        if let first = tools.first {
            // "Stovetop, microwave, air fryer": only the first word is capitalized.
            let rest = tools.dropFirst().map { $0.prefix(1).lowercased() + $0.dropFirst() }
            lines.append(([first] + rest).joined(separator: ", "))
        }

        if let name = prefs.store?.shopperLabel { lines.append("\(name) prices") }
        return lines
    }

    /// The last line — shown with a spinner until the response lands.
    public static func finalLine(budget: Int) -> String { "Fitting it into $\(budget)" }
}

public enum PlanLoadingTiming {
    /// The loading screen stays up at least this long, even if the API is faster.
    public static let minimumDuration: TimeInterval = 4
    /// Gap between one answer line appearing and the next.
    public static let lineInterval: TimeInterval = 0.7
    /// The progress bar fills toward this while waiting, then completes on response.
    public static let waitingProgress: Double = 0.9

    /// How much longer to hold the loading screen after the response arrived.
    public static func remainingHold(
        started: Date, now: Date, minimum: TimeInterval = minimumDuration
    ) -> TimeInterval {
        max(0, minimum - now.timeIntervalSince(started))
    }
}

public enum PaywallTeaserTrigger: Equatable, Sendable {
    /// Right after the reveal of the account's free plan.
    case freePlanReveal(planKey: String)
    /// Generating when the free plan is already used (403 pro_required).
    case freePlanUsed
    /// A swap answered 402 free_swaps_used.
    case freeSwapsUsed
    /// "New plan" on a free plan.
    case newPlanOnFreePlan
}

public enum PaywallTeaserPolicy {
    /// After the dinner cards finish animating in, wait this long, then present.
    public static let revealDelay: TimeInterval = 1.2

    /// Whether the teaser may be presented. Never for Pro. The reveal trigger fires
    /// once per free plan; the server-driven triggers (b–d) always show for a free
    /// account.
    public static func shouldShow(
        _ trigger: PaywallTeaserTrigger, isFreePlan: Bool = true, isPro: Bool, alreadyShown: (String) -> Bool
    ) -> Bool {
        guard !isPro else { return false }
        switch trigger {
        case .freePlanReveal(let key): return isFreePlan && !alreadyShown(key)
        case .freePlanUsed, .freeSwapsUsed, .newPlanOnFreePlan: return true
        }
    }

    /// A stable key for "this plan": its server id, else its dinner ids.
    public static func planKey(planID: String?, recipeIDs: [String]) -> String {
        planID ?? "local:" + recipeIDs.joined(separator: "|")
    }
}

/// Which free plans already showed the teaser, per account, so a restore or
/// relaunch never shows it twice for the same plan.
public struct PaywallTeaserStore {
    private static let baseKey = "paywall_teaser_shown_v1"
    private let defaults: UserDefaults
    private let storageKey: String

    public init(suiteName: String = AppGroup.identifier, userScope: String?) {
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
        storageKey = scopedStorageKey(Self.baseKey, userScope)
    }

    public init(defaults: UserDefaults, userScope: String?) {
        self.defaults = defaults
        storageKey = scopedStorageKey(Self.baseKey, userScope)
    }

    public func hasShown(planKey: String) -> Bool {
        (defaults.stringArray(forKey: storageKey) ?? []).contains(planKey)
    }

    public func markShown(planKey: String) {
        var keys = defaults.stringArray(forKey: storageKey) ?? []
        guard !keys.contains(planKey) else { return }
        keys.append(planKey)
        defaults.set(Array(keys.suffix(50)), forKey: storageKey)
    }
}
