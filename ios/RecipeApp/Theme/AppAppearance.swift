//
//  AppAppearance.swift
//  RecipeApp
//
//  The user's in-app appearance choice — independent of the iOS system setting.
//  Persisted in the shared App Group UserDefaults (same suite as PendingJobStore
//  etc.) so it's reachable from the Share Extension too, and read at the app root
//  to drive `.preferredColorScheme`.
//

import SwiftUI
import RecipeKit

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    /// `@AppStorage` key. Shared so the root (reader) and Settings (writer) stay
    /// in sync and updates apply immediately.
    static let storageKey = "appearancePreference"

    var id: String { rawValue }

    /// nil for `.system` (follow the OS); an explicit scheme otherwise.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

extension UserDefaults {
    /// Shared App Group defaults — the same suite the stores use, so the
    /// appearance choice is available to the Share Extension as well.
    static let appGroup = UserDefaults(suiteName: AppGroup.identifier) ?? .standard
}
