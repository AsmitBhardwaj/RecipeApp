//
//  MealPlanStore.swift
//  RecipeKit
//
//  Local persistence for the meal plan — a single JSON-encoded `[MealPlanEntry]`
//  under one key, mirroring `PendingJobStore`. This is deliberately the same
//  lightweight pattern: no external service, survives app launches (but not
//  deletion), no cross-device sync — matching the "no accounts yet" reality.
//
//  It shares the App Group suite for storage-convention consistency, though the
//  meal plan (unlike pending jobs) has no Share Extension consumer today.
//

import Foundation

public struct MealPlanStore {

    /// Single key holding the JSON-encoded `[MealPlanEntry]`.
    private static let storageKey = "meal_plan_entries_v1"

    private let defaults: UserDefaults

    /// Production initializer. Falls back to `.standard` if the App Group suite
    /// can't be opened, so the plan degrades to app-local rather than crashing.
    public init(suiteName: String = AppGroup.identifier) {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    /// Test/seam initializer: inject an ephemeral `UserDefaults` for host tests.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    // MARK: - Reads

    /// Every assignment across all days.
    public func all() -> [MealPlanEntry] {
        guard let data = defaults.data(forKey: Self.storageKey) else { return [] }
        return (try? JSONDecoder().decode([MealPlanEntry].self, from: data)) ?? []
    }

    /// Assignments for a single day key, oldest-assigned first.
    public func entries(on dayKey: String) -> [MealPlanEntry] {
        all()
            .filter { $0.dayKey == dayKey }
            .sorted { $0.addedAt < $1.addedAt }
    }

    // MARK: - Writes

    /// Append a new assignment.
    public func add(_ entry: MealPlanEntry) {
        var entries = all()
        entries.append(entry)
        write(entries)
    }

    /// Remove an assignment by its id.
    public func remove(id: String) {
        write(all().filter { $0.id != id })
    }

    private func write(_ entries: [MealPlanEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
