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
    /// Pantry (Kitchen) items for the budget mode's "Use my Kitchen" toggle.
    @StateObject private var pantry: PantryModel
    @EnvironmentObject private var subscriptions: SubscriptionService
    @EnvironmentObject private var cookingPreferences: CookingPreferencesModel

    private let userScope: String?
    private let sync: SyncCoordinator?

    /// This Week (manual) vs Plan on a Budget (generated).
    @State private var mode: PlanMode = .thisWeek
    private enum PlanMode: String, CaseIterable { case thisWeek = "This Week", budget = "Plan on a Budget" }

    init(jobs: PendingJobsModel, cookbooks: CookbooksModel, userScope: String? = nil, sync: SyncCoordinator? = nil) {
        self.jobs = jobs
        self.cookbooks = cookbooks
        self.userScope = userScope
        self.sync = sync
        _plan = StateObject(wrappedValue: MealPlanModel(userScope: userScope, sync: sync))
        _pantry = StateObject(wrappedValue: PantryModel(userScope: userScope, sync: sync))
    }

    /// Drives the add/change assignment sheet.
    @State private var assignFlow: AssignFlow?
    /// The assigned entry the user tapped, for the Change/Remove dialog.
    @State private var actionEntry: MealPlanEntry?
    /// The entry being moved (long-press → "Move to another day"), drives the
    /// day-picker dialog.
    @State private var moveEntry: MealPlanEntry?
    /// Drives the Account sheet from the header's account button (same as Recipes).
    @State private var showingAccount = false

    /// Resolves an entry's ingredient count from the in-session recipe list. The
    /// meal-plan entry itself only snapshots title + image (see MealPlanEntry), so
    /// the "N ingredients" caption is only shown when the full recipe is loaded
    /// this session; otherwise it's omitted rather than guessed.
    private var recipesById: [String: Recipe] {
        Dictionary(jobs.recipes.map { ($0.recipeId, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            modePicker
            if mode == .thisWeek {
                WeekSwitcherBar(plan: plan)
                Divider()
                dayList
            } else {
                budgetContent
            }
        }
        .foregroundStyle(Color.textPrimary)
        .appBackground()
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingAccount) {
            NavigationStack {
                AccountView()
            }
        }
        .sheet(item: $assignFlow) { flow in
            MealAssignSheet(
                mode: flow.mode,
                recipes: jobs.recipes,
                cookbooks: cookbooks,
                onPick: { selectedDate, slot, recipe in
                    switch flow {
                    case .add(let originalDate):
                        plan.add(recipe: recipe, to: selectedDate ?? originalDate, slot: slot)
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

    /// Title row: same treatment as the Recipes tab — large serif "Meal Plan."
    /// title with the shared circular account button wired to the same
    /// `AccountView` destination.
    private var header: some View {
        ScreenHeader("Meal Plan.") {
            CircleHeaderButton(
                systemImage: "person.crop.circle",
                accessibilityLabel: "Account"
            ) {
                showingAccount = true
            }
        }
    }

    /// The This Week / Plan on a Budget toggle, using the same `SegmentedPill`
    /// component as the Recipes tab's Cookbooks / All Recipes control.
    private var modePicker: some View {
        SegmentedPill(
            segments: PlanMode.allCases.map { .init(title: $0.rawValue, value: $0) },
            selection: $mode
        )
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.lg)
        .accessibilityLabel("Meal plan mode")
    }

    private var budgetContent: some View {
        BudgetPlanContainer(
            householdSize: cookingPreferences.householdSize,
            dietary: Array(cookingPreferences.dietaryPreferences),
            pantryNames: { pantry.items.map(\.name) },
            generate: { budget, household, dietary, pantryItems in
                guard let sync else { throw BudgetPlanError.invalidResponse("not signed in") }
                return try await sync.budgetPlan(
                    budget: budget, householdSize: household,
                    dietaryPreferences: dietary, pantryItems: pantryItems,
                    // The user's stored region drives the cost multiplier; when
                    // unset the server falls back to the national average.
                    region: cookingPreferences.region?.apiValue
                )
            },
            commit: { recipes in commitBudgetRecipes(recipes) },
            onSaved: { mode = .thisWeek }
        )
    }

    /// Commit accepted budget recipes into the existing meal_plan collection: one
    /// dinner per day starting today. Also persists each recipe body locally so it
    /// can be opened / aggregated later (the plan entry only snapshots title+image).
    private func commitBudgetRecipes(_ recipes: [PlannedRecipe]) {
        let store = RecipeStore(userScope: userScope)
        let today = Calendar.current.startOfDay(for: Date())
        for (index, planned) in recipes.enumerated() {
            let date = Calendar.current.date(byAdding: .day, value: index, to: today) ?? today
            plan.add(recipe: planned.recipe, to: date, slot: .dinner)
            store.upsert(planned.recipe)
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
/// accent (system font throughout; serif is reserved for screen titles, recipe
/// names, and empty-state headlines).
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

private struct SourceRoute: Hashable {
    let date: Date?
    let slot: MealSlot
}

private struct RecipeRoute: Hashable {
    let date: Date?
    let slot: MealSlot
    let source: RecipeSource
}

private struct MealAssignSheet: View {
    enum Mode { case add(day: Date); case change(slot: MealSlot) }

    let mode: Mode
    let recipes: [Recipe]
    @ObservedObject var cookbooks: CookbooksModel
    /// Chosen (optional add date, slot, recipe). Parent performs the mutation and dismisses.
    let onPick: (Date?, MealSlot, Recipe) -> Void
    let onCancel: () -> Void

    @State private var path = NavigationPath()
    @State private var addDate: Date

    init(
        mode: Mode,
        recipes: [Recipe],
        cookbooks: CookbooksModel,
        onPick: @escaping (Date?, MealSlot, Recipe) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.mode = mode
        self.recipes = recipes
        self.cookbooks = cookbooks
        self.onPick = onPick
        self.onCancel = onCancel
        switch mode {
        case .add(let day): _addDate = State(initialValue: day)
        case .change: _addDate = State(initialValue: Date())
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            root
                .navigationDestination(for: SourceRoute.self) { route in
                    SourceList(date: route.date, slot: route.slot, cookbooks: cookbooks, onCancel: nil)
                }
                .navigationDestination(for: RecipeRoute.self) { route in
                    RecipeList(slot: route.slot, source: route.source,
                               recipes: recipes, cookbooks: cookbooks) { slot, recipe in
                        onPick(route.date, slot, recipe)
                    }
                }
        }
        // Sage tint for Cancel + the back chevron, matching the app's buttons.
        .tint(Color.accentColor)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var root: some View {
        switch mode {
        case .add:
            AddMealPlanSetup(date: $addDate, onCancel: onCancel) { date, slot in
                path.append(SourceRoute(date: date, slot: slot))
            }
        case .change(let slot):
            SourceList(date: nil, slot: slot, cookbooks: cookbooks, onCancel: onCancel)
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

/// Step 1 (add only): confirm the date and choose a meal type before entering
/// the existing source and recipe pickers.
private struct AddMealPlanSetup: View {
    @Binding var date: Date
    let onCancel: () -> Void
    let onContinue: (Date, MealSlot) -> Void

    @State private var selectedSlot: MealSlot?

    private let columns = [
        GridItem(.flexible(), spacing: Theme.Spacing.md),
        GridItem(.flexible(), spacing: Theme.Spacing.md)
    ]

    /// The requested visual order is Breakfast/Lunch, then Dinner/Snack.
    private let slots: [MealSlot] = [.breakfast, .lunch, .dinner, .snacks]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                setupLabel("Date")

                HStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "calendar")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color.accentColor)

                    Text("Date")
                        .font(.body)
                        .foregroundStyle(Color.textPrimary)

                    Spacer(minLength: Theme.Spacing.sm)

                    DatePicker("Date", selection: $date, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .tint(Color.accentColor)
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .frame(minHeight: 56)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .strokeBorder(Color.hairline, lineWidth: 1)
                }
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                setupLabel("Meal Type")

                LazyVGrid(columns: columns, spacing: Theme.Spacing.md) {
                    ForEach(slots) { slot in
                        mealTypeButton(slot)
                    }
                }
            }

            Spacer(minLength: Theme.Spacing.lg)

            Button {
                guard let selectedSlot else { return }
                onContinue(date, selectedSlot)
            } label: {
                Text("Continue")
                    .font(.headline)
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(selectedSlot == nil)
            .opacity(selectedSlot == nil ? 0.5 : 1)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.top, Theme.Spacing.md)
        .padding(.bottom, Theme.Spacing.lg)
        .appBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            SheetTitle(title: "Add to Meal Plan")
            ToolbarItem(placement: .confirmationAction) {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Close")
            }
        }
    }

    private func setupLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.5)
            .foregroundStyle(Color.textSecondary)
    }

    private func mealTypeButton(_ slot: MealSlot) -> some View {
        let isSelected = selectedSlot == slot
        return Button {
            selectedSlot = slot
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: slot.iconName)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.textSecondary)

                Text(slot == .snacks ? "Snack" : slot.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.textPrimary)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(
                isSelected ? Color.creamTint : Color.surface,
                in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.hairline,
                                  lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Step 2: pick the source — All Recipes first, then the user's cookbooks.
private struct SourceList: View {
    let date: Date?
    let slot: MealSlot
    @ObservedObject var cookbooks: CookbooksModel
    /// Non-nil only when this is the sheet's root (i.e. Change mode).
    let onCancel: (() -> Void)?

    var body: some View {
        List {
            NavigationLink(value: RecipeRoute(date: date, slot: slot, source: .all)) {
                AssignRow(title: "All Recipes", subtitle: nil,
                          systemImage: "square.stack", tint: Color.secondaryAccent)
            }
            .cardRow()

            if !cookbooks.cookbooks.isEmpty {
                SectionLabel(text: "Cookbooks")
                ForEach(cookbooks.cookbooks) { cookbook in
                    NavigationLink(value: RecipeRoute(date: date, slot: slot, source: .cookbook(cookbook))) {
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
    .environmentObject(SubscriptionService())
    .environmentObject(CookingPreferencesModel(userScope: "preview"))
}
