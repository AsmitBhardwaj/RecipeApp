//
//  MealPlanView.swift
//  RecipeApp
//
//  The Meal Plan tab: a navigable Monday–Sunday week. Each day shows its four
//  meal slots (Breakfast / Lunch / Snacks / Dinner) as labeled sub-groups; only
//  slots with assignments render. "Add to a meal" walks slot → source
//  (All Recipes / a cookbook) → recipe (searchable). Tapping an assigned recipe
//  lets you Change (re-pick within the same slot) or Remove; swipe removes too.
//
//  Recipes come from `PendingJobsModel.recipes`; cookbook membership from
//  `CookbooksModel`; the plan itself from `MealPlanModel` (local `MealPlanStore`).
//

import SwiftUI
import RecipeKit

struct MealPlanView: View {
    @ObservedObject var jobs: PendingJobsModel
    @ObservedObject var cookbooks: CookbooksModel
    @StateObject private var plan = MealPlanModel()

    /// Drives the add/change assignment sheet.
    @State private var assignFlow: AssignFlow?
    /// The assigned entry the user tapped, for the Change/Remove dialog.
    @State private var actionEntry: MealPlanEntry?

    var body: some View {
        VStack(spacing: 0) {
            WeekSwitcherBar(plan: plan)
            Divider()
            dayList
        }
        .foregroundStyle(Color.textPrimary)
        .appBackground()
        .navigationTitle("Meal Plan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Meal Plan")
                    .font(.editorialTitle(size: 22))
                    .foregroundStyle(Color.textPrimary)
            }
        }
        .sheet(item: $assignFlow) { flow in
            MealAssignSheet(
                mode: flow.mode,
                recipes: jobs.recipes,
                cookbooks: cookbooks,
                plan: plan,
                onPick: { slot, recipe in
                    switch flow {
                    case .add(let date): plan.add(recipe: recipe, to: date, slot: slot)
                    case .change(let entry): plan.replace(entry, with: recipe)
                    }
                    assignFlow = nil
                },
                onCancel: { assignFlow = nil }
            )
        }
        .confirmationDialog(
            "Change this meal?",
            isPresented: Binding(get: { actionEntry != nil }, set: { if !$0 { actionEntry = nil } }),
            presenting: actionEntry
        ) { entry in
            Button("Change recipe") { assignFlow = .change(entry: entry); actionEntry = nil }
            Button("Remove", role: .destructive) { plan.remove(entry); actionEntry = nil }
            Button("Cancel", role: .cancel) { actionEntry = nil }
        } message: { entry in
            Text(entry.recipeTitle)
        }
    }

    private var dayList: some View {
        List {
            ForEach(plan.weekDays, id: \.self) { day in
                Section {
                    daySlots(for: day)

                    Button {
                        assignFlow = .add(date: day)
                    } label: {
                        Label("Add to a meal", systemImage: "plus")
                            .font(.subheadline)
                            .foregroundStyle(.tint)
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                } header: {
                    DayHeader(date: day, isToday: plan.isToday(day))
                }
            }
        }
        .listStyle(.plain)
    }

    /// The four slots for a day, rendering only those that have assignments.
    @ViewBuilder
    private func daySlots(for day: Date) -> some View {
        let dayEntries = plan.entries(for: day)
        if dayEntries.isEmpty {
            Text("Nothing planned")
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)
                .tornEdgeCardRow()
        } else {
            ForEach(MealSlot.allCases) { slot in
                let slotEntries = dayEntries.filter { $0.mealSlot == slot }
                if !slotEntries.isEmpty {
                    slotLabel(slot)
                    ForEach(slotEntries) { entry in
                        Button {
                            actionEntry = entry
                        } label: {
                            MealPlanEntryRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                        .tornEdgeCardRow()
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                plan.remove(entry)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }

    private func slotLabel(_ slot: MealSlot) -> some View {
        Text(slot.displayName.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.5)
            .foregroundStyle(Color.textSecondary)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .padding(.top, 6)
    }
}

// MARK: - Assignment flow

/// What the assignment sheet is doing. `.add` starts at the slot picker; `.change`
/// skips it (the slot is fixed to the tapped entry's) and starts at the source.
private enum AssignFlow: Identifiable {
    case add(date: Date)
    case change(entry: MealPlanEntry)

    var id: String {
        switch self {
        case .add(let date): return "add-\(date.timeIntervalSince1970)"
        case .change(let entry): return "change-\(entry.id)"
        }
    }

    var mode: MealAssignSheet.Mode {
        switch self {
        case .add(let date): return .add(day: date)
        case .change(let entry): return .change(slot: entry.mealSlot)
        }
    }
}

/// SF Symbols per meal slot (view layer — keeps `MealSlot` UI-free). A simple
/// time-of-day set, tinted in the app palette at the call site.
private extension MealSlot {
    var iconName: String {
        switch self {
        case .breakfast: return "sunrise"
        case .lunch: return "sun.max"
        case .snacks: return "carrot"
        case .dinner: return "moon.stars"
        }
    }
}

// MARK: - Week switcher

private struct WeekSwitcherBar: View {
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
        .padding(.vertical, 4)
    }

    private var rangeText: String {
        guard let first = plan.weekDays.first, let last = plan.weekDays.last else { return "" }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        let start = f.string(from: first)
        f.dateFormat = "MMM d, yyyy"
        let end = f.string(from: last)
        return "\(start) – \(end)"
    }
}

// MARK: - Day header

private struct DayHeader: View {
    let date: Date
    let isToday: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(weekdayText)
            if isToday {
                Text("Today")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondaryAccent, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
    }

    private var weekdayText: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f.string(from: date)
    }
}

// MARK: - Assigned recipe row

private struct MealPlanEntryRow: View {
    let entry: MealPlanEntry

    var body: some View {
        HStack(spacing: 12) {
            RecipeImageView(imageUrl: entry.recipeImageURL, fallbackSeed: entry.recipeId, fallbackTitle: entry.recipeTitle, placeholderSymbolSize: 16)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(entry.recipeTitle)
                .font(.subheadline)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - Assign sheet (slot → source → recipe)

/// Recipe source in the picker: everything, or one cookbook's members.
private enum RecipeSource: Hashable {
    case all
    case cookbook(Cookbook)
}

private struct SourceRoute: Hashable { let slot: MealSlot }
private struct RecipeRoute: Hashable { let slot: MealSlot; let source: RecipeSource }

private struct MealAssignSheet: View {
    enum Mode { case add(day: Date); case change(slot: MealSlot) }

    let mode: Mode
    let recipes: [Recipe]
    @ObservedObject var cookbooks: CookbooksModel
    @ObservedObject var plan: MealPlanModel
    /// Chosen (slot, recipe). Parent performs the mutation and dismisses.
    let onPick: (MealSlot, Recipe) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            root
                .navigationDestination(for: SourceRoute.self) { route in
                    SourceList(slot: route.slot, cookbooks: cookbooks, onCancel: nil)
                }
                .navigationDestination(for: RecipeRoute.self) { route in
                    RecipeList(slot: route.slot, source: route.source,
                               recipes: recipes, cookbooks: cookbooks, onPick: onPick)
                }
        }
        // Sage tint for Cancel + the back chevron, matching the app's buttons.
        .tint(Color.accentColor)
    }

    @ViewBuilder
    private var root: some View {
        switch mode {
        case .add(let day):
            SlotList(day: day, plan: plan, onCancel: onCancel)
        case .change(let slot):
            SourceList(slot: slot, cookbooks: cookbooks, onCancel: onCancel)
        }
    }
}

/// A serif screen title in the nav bar, matching the app's other screens.
private struct SheetTitle: ToolbarContent {
    let title: String
    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Text(title)
                .font(.editorialTitle(size: 20))
                .foregroundStyle(Color.textPrimary)
        }
    }
}

/// A caption-style section label (matches the Grocery list's headers).
private struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.5)
            .foregroundStyle(Color.textSecondary)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .padding(.top, 6)
    }
}

/// A card row: palette-tinted icon, body-font title, optional subtitle.
private struct AssignRow: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(Color.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// Step 1 (add only): pick which meal. Each row shows the slot's current state.
private struct SlotList: View {
    let day: Date
    @ObservedObject var plan: MealPlanModel
    let onCancel: () -> Void

    var body: some View {
        List(MealSlot.allCases) { slot in
            NavigationLink(value: SourceRoute(slot: slot)) {
                AssignRow(title: slot.displayName,
                          subtitle: subtitle(for: slot),
                          systemImage: slot.iconName,
                          tint: Color.accentColor)
            }
            .tornEdgeCardRow()
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .appBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            SheetTitle(title: "Choose a meal")
            ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
        }
    }

    /// Live per-slot state: recipe name if one, "N recipes" if more, else "Empty".
    private func subtitle(for slot: MealSlot) -> String {
        let entries = plan.entries(for: day, slot: slot)
        switch entries.count {
        case 0: return "Empty"
        case 1: return entries[0].recipeTitle
        default: return "\(entries.count) recipes"
        }
    }
}

/// Step 2: pick the source — All Recipes first, then the user's cookbooks.
private struct SourceList: View {
    let slot: MealSlot
    @ObservedObject var cookbooks: CookbooksModel
    /// Non-nil only when this is the sheet's root (i.e. Change mode).
    let onCancel: (() -> Void)?

    var body: some View {
        List {
            NavigationLink(value: RecipeRoute(slot: slot, source: .all)) {
                AssignRow(title: "All Recipes", subtitle: nil,
                          systemImage: "square.stack", tint: Color.secondaryAccent)
            }
            .tornEdgeCardRow()

            if !cookbooks.cookbooks.isEmpty {
                SectionLabel(text: "Cookbooks")
                ForEach(cookbooks.cookbooks) { cookbook in
                    NavigationLink(value: RecipeRoute(slot: slot, source: .cookbook(cookbook))) {
                        AssignRow(title: cookbook.name, subtitle: nil,
                                  systemImage: "book.closed", tint: Color.accentColor)
                    }
                    .tornEdgeCardRow()
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .appBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            SheetTitle(title: "Add to \(slot.displayName)")
            if let onCancel {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
            }
        }
    }
}

/// Step 3: pick the recipe, with search. (Behavior unchanged; carded to match.)
private struct RecipeList: View {
    let slot: MealSlot
    let source: RecipeSource
    let recipes: [Recipe]
    @ObservedObject var cookbooks: CookbooksModel
    let onPick: (MealSlot, Recipe) -> Void

    @State private var search = ""

    private var sourceRecipes: [Recipe] {
        switch source {
        case .all:
            return recipes
        case .cookbook(let cookbook):
            let ids = cookbooks.recipeIds(in: cookbook.id)
            return recipes.filter { ids.contains($0.recipeId) }
        }
    }

    private var filtered: [Recipe] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return sourceRecipes }
        return sourceRecipes.filter { $0.title.lowercased().contains(query) }
    }

    private var title: String {
        switch source {
        case .all: return "All Recipes"
        case .cookbook(let cookbook): return cookbook.name
        }
    }

    var body: some View {
        Group {
            if sourceRecipes.isEmpty {
                ContentUnavailableView {
                    Label("No recipes here", systemImage: "book.closed")
                } description: {
                    Text("Add recipes in the Recipes tab first, then assign them here.")
                }
            } else {
                List(filtered) { recipe in
                    Button {
                        onPick(slot, recipe)
                    } label: {
                        RecipeRowView(recipe: recipe)
                    }
                    .buttonStyle(.plain)
                    .tornEdgeCardRow()
                }
                .listStyle(.plain)
                .searchable(text: $search, prompt: "Search recipes")
            }
        }
        .scrollContentBackground(.hidden)
        .appBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { SheetTitle(title: title) }
    }
}

#Preview {
    NavigationStack {
        MealPlanView(
            jobs: PendingJobsModel(provider: MockRecipeProvider()),
            cookbooks: CookbooksModel()
        )
    }
}
