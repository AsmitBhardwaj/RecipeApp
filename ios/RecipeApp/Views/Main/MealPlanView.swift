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
    @StateObject private var plan: MealPlanModel

    init(jobs: PendingJobsModel, cookbooks: CookbooksModel, userScope: String? = nil, sync: SyncCoordinator? = nil) {
        self.jobs = jobs
        self.cookbooks = cookbooks
        _plan = StateObject(wrappedValue: MealPlanModel(userScope: userScope, sync: sync))
    }

    /// Drives the add/change assignment sheet.
    @State private var assignFlow: AssignFlow?
    /// The assigned entry the user tapped, for the Change/Remove dialog.
    @State private var actionEntry: MealPlanEntry?
    /// The entry being moved (long-press → "Move to another day"), drives the
    /// day-picker dialog.
    @State private var moveEntry: MealPlanEntry?

    /// Resolves an entry's ingredient count from the in-session recipe list. The
    /// meal-plan entry itself only snapshots title + image (see MealPlanEntry), so
    /// the "N ingredients" caption is only shown when the full recipe is loaded
    /// this session; otherwise it's omitted rather than guessed.
    private var recipesById: [String: Recipe] {
        Dictionary(jobs.recipes.map { ($0.recipeId, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader("Meal Plan")
            WeekSwitcherBar(plan: plan)
            Divider()
            dayList
        }
        .foregroundStyle(Color.textPrimary)
        .appBackground()
        .toolbar(.hidden, for: .navigationBar)
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
        .confirmationDialog(
            "Move to another day",
            isPresented: Binding(get: { moveEntry != nil }, set: { if !$0 { moveEntry = nil } }),
            presenting: moveEntry
        ) { entry in
            ForEach(otherDays(for: entry), id: \.self) { day in
                Button(moveDayLabel(day)) { plan.move(entry, to: day); moveEntry = nil }
            }
            Button("Cancel", role: .cancel) { moveEntry = nil }
        } message: { entry in
            Text(entry.recipeTitle)
        }
    }

    private var dayList: some View {
        List {
            ForEach(plan.weekDays, id: \.self) { day in
                Section {
                    dayRows(for: day)
                }
            }
        }
        .listStyle(.plain)
        // Bottom inset so the last day never sits under the floating tab bar.
        .contentMargins(.bottom, Theme.Spacing.tabBarClearance, for: .scrollContent)
    }

    /// The rows for one day: an "Add a meal" row when empty, otherwise one row per
    /// meal in order added — the date column on the first row, the single trailing
    /// "+" on the last.
    @ViewBuilder
    private func dayRows(for day: Date) -> some View {
        let entries = plan.entries(for: day)
        if entries.isEmpty {
            EmptyDayRow(date: day, isToday: plan.isToday(day)) {
                assignFlow = .add(date: day)
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        } else {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                MealAgendaRow(
                    date: day,
                    isToday: plan.isToday(day),
                    showDateColumn: index == 0,
                    mealCount: entries.count,
                    entry: entry,
                    ingredientCount: recipesById[entry.recipeId]?.ingredients.count,
                    showAdd: index == entries.count - 1,
                    onAdd: { assignFlow = .add(date: day) },
                    onTap: { actionEntry = entry }
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { plan.remove(entry) } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button { moveEntry = entry } label: {
                        Label("Move to another day", systemImage: "calendar")
                    }
                    Button(role: .destructive) { plan.remove(entry) } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
            }
        }
    }

    /// The visible week's days other than the entry's current one — the targets in
    /// the "Move to another day" picker.
    private func otherDays(for entry: MealPlanEntry) -> [Date] {
        plan.weekDays.filter { plan.dayKey(for: $0) != entry.dayKey }
    }

    private func moveDayLabel(_ day: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f.string(from: day)
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

// MARK: - Date column (left of each day's agenda rows)

/// The leading date column: weekday abbreviation, day number, and — only when a
/// day holds 2+ meals — a small "N meals" caption. Today reads in the sage
/// accent (system font throughout; serif is reserved for titles + recipe names).
private struct DateColumn: View {
    let date: Date
    let isToday: Bool
    /// 0 for an empty day; the caption shows only at 2+.
    let mealCount: Int

    private let width: CGFloat = 52

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(weekday)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(isToday ? Color.accentColor : Color.textSecondary)
            Text(dayNumber)
                .font(.title3.weight(.semibold))
                .foregroundStyle(isToday ? Color.accentColor : Color.textPrimary)
            if mealCount >= 2 {
                Text("\(mealCount) meals")
                    .font(.caption2)
                    .foregroundStyle(Color.textSecondary)
            }
        }
        .frame(width: width, alignment: .leading)
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

// MARK: - Empty-day row ("+ Add a meal")

private struct EmptyDayRow: View {
    let date: Date
    let isToday: Bool
    let onAdd: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            DateColumn(date: date, isToday: isToday, mealCount: 0)
            Button(action: onAdd) {
                Label("Add a meal", systemImage: "plus")
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Meal agenda row (one meal within a day)

/// One meal in a day's stack. The date column renders on the first row only
/// (`showDateColumn`), top-aligned so it sits beside the first meal; the single
/// trailing "+" renders on the last row only (`showAdd`). Tapping the meal opens
/// the Change/Remove dialog.
private struct MealAgendaRow: View {
    let date: Date
    let isToday: Bool
    let showDateColumn: Bool
    let mealCount: Int
    let entry: MealPlanEntry
    let ingredientCount: Int?
    let showAdd: Bool
    let onAdd: () -> Void
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Date column reserves its width on every row so meals stay aligned;
            // it's only drawn on the first row of the day.
            DateColumn(date: date, isToday: isToday, mealCount: mealCount)
                .opacity(showDateColumn ? 1 : 0)

            Button(action: onTap) {
                HStack(spacing: 12) {
                    RecipeImageView(imageUrl: entry.recipeImageURL,
                                    fallbackSeed: entry.recipeId,
                                    fallbackTitle: entry.recipeTitle,
                                    placeholderSymbolSize: 18)
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.recipeTitle)
                            .font(.editorialTitle(size: 16, relativeTo: .body))
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if let ingredientCount {
                            Text("\(ingredientCount) ingredient\(ingredientCount == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(Color.textSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showAdd {
                CircleHeaderButton(systemImage: "plus", primary: true,
                                   accessibilityLabel: "Add a meal", action: onAdd)
            }
        }
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
            .cardRow()
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
            .cardRow()

            if !cookbooks.cookbooks.isEmpty {
                SectionLabel(text: "Cookbooks")
                ForEach(cookbooks.cookbooks) { cookbook in
                    NavigationLink(value: RecipeRoute(slot: slot, source: .cookbook(cookbook))) {
                        AssignRow(title: cookbook.name, subtitle: nil,
                                  systemImage: "book.closed", tint: Color.accentColor)
                    }
                    .cardRow()
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
                    .cardRow()
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
