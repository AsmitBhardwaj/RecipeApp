//
//  MealPlanModel.swift
//  RecipeApp
//
//  Observable coordinator for the Meal Plan tab, backed by `MealPlanStore`
//  (mirrors how `PendingJobsModel` wraps `PendingJobStore`). Owns the currently
//  visible week (navigable) and the assignments for it, exposing add/remove and
//  week navigation. Reads recipes for the picker from `PendingJobsModel.recipes`
//  at the call site — this model only manages the plan itself.
//
//  Week convention: Monday–Sunday. Day keys are stable local-day strings
//  ("yyyy-MM-dd") so assignments land on the calendar day the user picked.
//

import Foundation
import RecipeKit

@MainActor
final class MealPlanModel: ObservableObject, SyncRefreshable {

    /// Monday 00:00 of the visible week.
    @Published private(set) var weekStart: Date
    /// Assignments for the visible week, grouped by day key.
    @Published private(set) var entriesByDay: [String: [MealPlanEntry]] = [:]

    private let store: MealPlanStore
    private let calendar: Calendar
    /// Sync hub (nil in previews/unscoped builds → no sync recording).
    private let sync: SyncCoordinator?

    init(userScope: String? = nil, sync: SyncCoordinator? = nil, reference: Date = Date()) {
        self.store = MealPlanStore(userScope: userScope)
        self.sync = sync
        var cal = Calendar.current
        cal.firstWeekday = 2 // Monday
        self.calendar = cal
        self.weekStart = Self.weekStart(containing: reference, calendar: cal)
        reload()
        sync?.registerRefreshable(self)
    }

    /// Refresh the visible week from disk after a sync pull wrote new meal-plan
    /// entries (the applier writes straight to `MealPlanStore`, not this model).
    /// `reload()` is inherently merge-safe: every local mutation already persists
    /// to the store before reloading, so the store is the single source of truth —
    /// this drops nothing resolved this session and re-derives the same ordering.
    func refreshFromStore() {
        reload()
    }

    // MARK: - Week model

    /// The seven `Date`s (Mon…Sun) of the visible week.
    var weekDays: [Date] {
        (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
    }

    /// Whether the visible week is the one containing today.
    var isCurrentWeek: Bool {
        weekStart == Self.weekStart(containing: Date(), calendar: calendar)
    }

    func dayKey(for date: Date) -> String {
        Self.dayKeyFormatter.string(from: date)
    }

    func isToday(_ date: Date) -> Bool {
        calendar.isDateInToday(date)
    }

    func entries(for date: Date) -> [MealPlanEntry] {
        entriesByDay[dayKey(for: date)] ?? []
    }

    /// A day's entries for one meal slot, time-ordered (multiple allowed).
    func entries(for date: Date, slot: MealSlot) -> [MealPlanEntry] {
        entries(for: date).filter { $0.mealSlot == slot }
    }

    // MARK: - Navigation

    func goToPreviousWeek() { shiftWeek(by: -7) }
    func goToNextWeek() { shiftWeek(by: 7) }

    func goToThisWeek() {
        weekStart = Self.weekStart(containing: Date(), calendar: calendar)
        reload()
    }

    private func shiftWeek(by days: Int) {
        guard let shifted = calendar.date(byAdding: .day, value: days, to: weekStart) else { return }
        weekStart = shifted
        reload()
    }

    // MARK: - Mutations

    func add(recipe: Recipe, to date: Date, slot: MealSlot) {
        let entry = MealPlanEntry(
            dayKey: dayKey(for: date),
            mealSlot: slot,
            recipeId: recipe.recipeId,
            recipeTitle: recipe.title,
            recipeImageURL: recipe.imageUrl
        )
        store.add(entry)
        recordUpsert(entry)
        reload()
    }

    /// Swap the recipe on an existing assignment, keeping its day and meal slot
    /// (the "Change" action). Implemented as remove-then-add at the store level.
    func replace(_ entry: MealPlanEntry, with recipe: Recipe) {
        store.remove(id: entry.id)
        recordDelete(entry.id)
        let replacement = MealPlanEntry(
            dayKey: entry.dayKey,
            mealSlot: entry.mealSlot,
            recipeId: recipe.recipeId,
            recipeTitle: recipe.title,
            recipeImageURL: recipe.imageUrl
        )
        store.add(replacement)
        recordUpsert(replacement)
        reload()
    }

    func remove(_ entry: MealPlanEntry) {
        store.remove(id: entry.id)
        recordDelete(entry.id)
        reload()
    }

    /// Move an assignment to another day (the "Move to another day" long-press
    /// action), keeping its meal slot. Like `replace`, this is remove-then-add at
    /// the store level; the moved entry sorts to the end of the target day's
    /// order (a fresh `addedAt`). No-op when the target day is unchanged.
    func move(_ entry: MealPlanEntry, to date: Date) {
        let targetKey = dayKey(for: date)
        guard targetKey != entry.dayKey else { return }
        store.remove(id: entry.id)
        recordDelete(entry.id)
        let moved = MealPlanEntry(
            dayKey: targetKey,
            mealSlot: entry.mealSlot,
            recipeId: entry.recipeId,
            recipeTitle: entry.recipeTitle,
            recipeImageURL: entry.recipeImageURL
        )
        store.add(moved)
        recordUpsert(moved)
        reload()
    }

    private func recordUpsert(_ entry: MealPlanEntry) {
        sync?.record(.mealPlan, itemId: entry.id, payload: SyncCodec.encode(entry))
    }

    private func recordDelete(_ id: String) {
        sync?.record(.mealPlan, itemId: id, payload: nil, deleted: true)
    }

    // MARK: - Loading

    /// Pull the visible week's entries from the store and regroup by day.
    private func reload() {
        let keys = Set(weekDays.map { dayKey(for: $0) })
        var grouped: [String: [MealPlanEntry]] = [:]
        for entry in store.all() where keys.contains(entry.dayKey) {
            grouped[entry.dayKey, default: []].append(entry)
        }
        for key in grouped.keys {
            grouped[key]?.sort { $0.addedAt < $1.addedAt }
        }
        entriesByDay = grouped
    }

    // MARK: - Date helpers

    /// Start-of-week (Monday, since `firstWeekday == 2`) for the given date.
    static func weekStart(containing date: Date, calendar: Calendar) -> Date {
        let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: comps) ?? calendar.startOfDay(for: date)
    }

    static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
