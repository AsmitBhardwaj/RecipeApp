//
//  GroceryListView.swift
//  RecipeApp
//
//  The Grocery List tab: a shopping list derived live from the Meal Plan for a
//  chosen period (a single day or the whole visible week). Nothing about the
//  ingredient list is stored — it is recomputed from meal-plan state on every
//  render, so it always reflects the current plan (add/remove a recipe over in
//  Meal Plan and it shows up here next time this tab appears). Only two things
//  persist: which items are checked off, and hand-added manual items — both in
//  `GroceryListModel` / `GroceryCheckStore`.
//
//  Week navigation is reused from `MealPlanModel` (weekDays, dayKey, nav) rather
//  than reinventing date logic. Entries themselves are read fresh from
//  `MealPlanStore` each render (not MealPlanModel's cached copy) so plan edits
//  made on the other tab are reflected without a stale cache. Ingredients are
//  resolved from `PendingJobsModel.recipes`, which is seeded from the on-device
//  `RecipeStore` at launch, so recipes extracted in earlier sessions resolve
//  reliably. A residual entry pointing at a recipe that's genuinely gone (e.g. a
//  future delete) surfaces as an honest note rather than silently vanishing.
//

import SwiftUI
import RecipeKit

struct GroceryListView: View {
    @ObservedObject var jobs: PendingJobsModel
    @StateObject private var plan = MealPlanModel()
    @StateObject private var model = GroceryListModel()

    /// Fresh read source for meal-plan entries — bypasses MealPlanModel's cache
    /// so edits from the Meal Plan tab are reflected live.
    private let mealStore = MealPlanStore()

    @State private var scope: Scope = .day
    /// The day selected in Day scope, as a "yyyy-MM-dd" key. Always one of the
    /// visible week's days (kept in range by `syncSelectedDay`).
    @State private var selectedDayKey: String = ""
    @State private var showingAddItem = false
    @State private var newItemText = ""

    enum Scope: String, CaseIterable, Identifiable {
        case day = "Day"
        case week = "Week"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Scope", selection: $scope) {
                ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)

            WeekNavBar(plan: plan)

            if scope == .day {
                DayStrip(plan: plan, selectedDayKey: $selectedDayKey)
                    .padding(.bottom, 6)
            }

            Divider()

            content
        }
        .foregroundStyle(Color.textPrimary)
        .appBackground()
        .navigationTitle("Grocery List")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Grocery List")
                    .font(.editorialTitle(size: 22))
                    .foregroundStyle(Color.textPrimary)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddItem = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add item")
            }
        }
        .onAppear(perform: syncSelectedDay)
        .onChange(of: plan.weekStart) { _, _ in syncSelectedDay() }
        .alert("Add item", isPresented: $showingAddItem) {
            TextField("e.g. paper towels", text: $newItemText)
            Button("Add") {
                model.addManual(name: newItemText, period: periodKey)
                newItemText = ""
            }
            Button("Cancel", role: .cancel) { newItemText = "" }
        } message: {
            Text("Adds a one-off item to this \(scope == .day ? "day" : "week")'s list. Not tied to any recipe.")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isEmpty {
            emptyState
        } else {
            List {
                if resolution.unresolved > 0 {
                    Section {
                        Text(unresolvedNote)
                            .font(.caption)
                            .foregroundStyle(Color.textSecondary)
                            .tornEdgeCardRow()
                    }
                }

                ForEach(sections) { section in
                    Section {
                        ForEach(section.items) { item in
                            let key = "\(periodKey)|\(item.stableKey)"
                            GroceryCheckRow(
                                text: item.displayString,
                                detail: item.sources.joined(separator: ", "),
                                checked: model.isChecked(key)
                            ) {
                                model.toggle(key)
                            }
                            .tornEdgeCardRow()
                        }
                    } header: {
                        sectionHeader(section.category.displayName)
                    }
                }

                if !manualForPeriod.isEmpty {
                    Section {
                        ForEach(manualForPeriod) { item in
                            GroceryCheckRow(
                                text: item.name,
                                detail: nil,
                                checked: model.isChecked(item.checkKey)
                            ) {
                                model.toggle(item.checkKey)
                            }
                            .tornEdgeCardRow()
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    model.removeManual(item)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        sectionHeader("Added by you")
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing to shop for", systemImage: "cart")
        } description: {
            Text("No meals planned for this \(scope == .day ? "day" : "week"). Add recipes in Meal Plan to build your list — or tap + to add an item yourself.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.5)
            .foregroundStyle(Color.textSecondary)
    }

    // MARK: - Derivation (recomputed every render — live, never cached)

    /// Stable identity for the current period, prefixed onto every checked-state
    /// key so Day and Week keep independent checkmarks.
    private var periodKey: String {
        switch scope {
        case .day:
            return "day:\(selectedDayKey)"
        case .week:
            let firstKey = plan.weekDays.first.map { plan.dayKey(for: $0) } ?? ""
            return "week:\(firstKey)"
        }
    }

    /// Meal-plan assignments in scope, read FRESH from the store (not the cache).
    private var periodEntries: [MealPlanEntry] {
        switch scope {
        case .day:
            return mealStore.entries(on: selectedDayKey)
        case .week:
            return plan.weekDays.flatMap { mealStore.entries(on: plan.dayKey(for: $0)) }
        }
    }

    /// Resolve entries to full recipes via the in-memory session list. Entries
    /// whose recipe isn't currently loaded are counted, not dropped silently.
    private var resolution: (recipes: [Recipe], unresolved: Int) {
        let byId = Dictionary(jobs.recipes.map { ($0.recipeId, $0) }, uniquingKeysWith: { first, _ in first })
        var recipes: [Recipe] = []
        var unresolved = 0
        for entry in periodEntries {
            if let recipe = byId[entry.recipeId] {
                recipes.append(recipe)
            } else {
                unresolved += 1
            }
        }
        return (recipes, unresolved)
    }

    /// Aggregated, category-grouped shopping list. Categories appear in
    /// `GroceryCategory.allCases` order; items are alphabetized within each.
    private var sections: [CategorySection] {
        let items = GroceryAggregator.aggregate(recipes: resolution.recipes)
        let byCategory = Dictionary(grouping: items, by: { $0.category })
        return GroceryCategory.allCases.compactMap { category in
            guard let list = byCategory[category], !list.isEmpty else { return nil }
            return CategorySection(
                category: category,
                items: list.sorted { $0.name.lowercased() < $1.name.lowercased() }
            )
        }
    }

    private var manualForPeriod: [GroceryManualItem] {
        model.manualItems(inPeriod: periodKey)
    }

    private var isEmpty: Bool {
        sections.isEmpty && manualForPeriod.isEmpty
    }

    private var unresolvedNote: String {
        let n = resolution.unresolved
        let word = n == 1 ? "item references a recipe" : "items reference recipes"
        return "\(n) planned \(word) that's no longer available, so \(n == 1 ? "its" : "their") ingredients aren't included."
    }

    // MARK: - Day selection

    /// Keep `selectedDayKey` within the visible week: default to today when it's
    /// in range, otherwise the first day of the week.
    private func syncSelectedDay() {
        let keys = plan.weekDays.map { plan.dayKey(for: $0) }
        guard !keys.contains(selectedDayKey) else { return }
        let todayKey = plan.dayKey(for: Date())
        selectedDayKey = keys.contains(todayKey) ? todayKey : (keys.first ?? "")
    }
}

// MARK: - Category section (Identifiable wrapper for ForEach)

private struct CategorySection: Identifiable {
    let category: GroceryCategory
    let items: [GroceryLineItem]
    var id: GroceryCategory { category }
}

// MARK: - Week nav bar (reuses MealPlanModel's date logic)

private struct WeekNavBar: View {
    @ObservedObject var plan: MealPlanModel

    var body: some View {
        HStack {
            Button {
                plan.goToPreviousWeek()
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 44, height: 44)
                    .foregroundStyle(.tint)
            }

            Spacer()

            VStack(spacing: 2) {
                Text(rangeText)
                    .font(.headline)
                if !plan.isCurrentWeek {
                    Button("This Week") { plan.goToThisWeek() }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }

            Spacer()

            Button {
                plan.goToNextWeek()
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 44, height: 44)
                    .foregroundStyle(.tint)
            }
        }
        .padding(.horizontal, 8)
    }

    private var rangeText: String {
        guard let first = plan.weekDays.first, let last = plan.weekDays.last else { return "" }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        let start = f.string(from: first)
        f.dateFormat = "MMM d, yyyy"
        return "\(start) – \(f.string(from: last))"
    }
}

// MARK: - Day strip (Day scope: pick one of the week's days)

private struct DayStrip: View {
    @ObservedObject var plan: MealPlanModel
    @Binding var selectedDayKey: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(plan.weekDays, id: \.self) { day in
                    let key = plan.dayKey(for: day)
                    DayChip(
                        date: day,
                        isSelected: key == selectedDayKey,
                        isToday: plan.isToday(day)
                    ) {
                        selectedDayKey = key
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }
}

private struct DayChip: View {
    let date: Date
    let isSelected: Bool
    let isToday: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 2) {
                Text(weekday).font(.caption2.weight(.semibold))
                Text(dayNumber).font(.headline)
            }
            .frame(width: 44, height: 52)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.secondaryAccent : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isToday && !isSelected ? Color.secondaryAccent : Color.clear,
                        lineWidth: 1.5
                    )
            }
            .foregroundStyle(isSelected ? Color.white : Color.textPrimary)
        }
        .buttonStyle(.plain)
    }

    private var weekday: String {
        let f = DateFormatter(); f.dateFormat = "EEE"
        return f.string(from: date)
    }

    private var dayNumber: String {
        let f = DateFormatter(); f.dateFormat = "d"
        return f.string(from: date)
    }
}

// MARK: - Checkable row

private struct GroceryCheckRow: View {
    let text: String
    let detail: String?
    let checked: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(checked ? Color.secondaryAccent : Color.textSecondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(text)
                        .font(.body)
                        .strikethrough(checked, color: Color.textSecondary)
                        .foregroundStyle(checked ? Color.textSecondary : Color.textPrimary)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    NavigationStack {
        GroceryListView(jobs: PendingJobsModel(provider: MockRecipeProvider()))
    }
}
