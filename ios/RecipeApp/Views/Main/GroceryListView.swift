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
    @StateObject private var plan: MealPlanModel
    @StateObject private var model: GroceryListModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Fresh read source for meal-plan entries — bypasses MealPlanModel's cache
    /// so edits from the Meal Plan tab are reflected live.
    private let mealStore: MealPlanStore

    init(jobs: PendingJobsModel, userScope: String? = nil, sync: SyncCoordinator? = nil) {
        self.jobs = jobs
        _plan = StateObject(wrappedValue: MealPlanModel(userScope: userScope, sync: sync))
        _model = StateObject(wrappedValue: GroceryListModel(userScope: userScope, sync: sync))
        self.mealStore = MealPlanStore(userScope: userScope)
    }

    @State private var scope: Scope = .day
    /// The day selected in Day scope, as a "yyyy-MM-dd" key. Always one of the
    /// visible week's days (kept in range by `syncSelectedDay`).
    @State private var selectedDayKey: String = ""
    @State private var showingAddItem = false
    @State private var newItemText = ""
    @State private var showingShareToday = false

    // Celebration state. `confettiTrigger` fires a burst on increment;
    // `celebratedSignature` records the exact set of items whose completion was
    // already celebrated, so unchecking + rechecking the same final item does not
    // re-fire — only a meaningfully different list (new/removed items, a changed
    // plan) produces a new signature and a fresh celebration.
    @State private var confettiTrigger = 0
    @State private var showDoneBanner = false
    @State private var celebratedSignature: String?
    @State private var bannerDismissTask: Task<Void, Never>?

    enum Scope: String, CaseIterable, Identifiable {
        case day = "Day"
        case week = "Week"
        var id: String { rawValue }
    }

    var body: some View {
        ZStack(alignment: .top) {
            listStack

            if !reduceMotion {
                ConfettiView(trigger: confettiTrigger)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            if showDoneBanner {
                completionBanner
                    .padding(.top, 12)
                    .transition(reduceMotion
                                ? .opacity
                                : .move(edge: .top).combined(with: .opacity))
            }
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
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingShareToday = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(!canShareToday)
                .accessibilityLabel("Share today's grocery list")
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
        .sheet(isPresented: $showingShareToday) {
            ActivityView(items: [todayShareText])
        }
        .onAppear(perform: syncSelectedDay)
        .onChange(of: plan.weekStart) { _, _ in syncSelectedDay() }
        .onChange(of: isComplete) { _, complete in
            if complete { celebrateCompletion() }
        }
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

    private var listStack: some View {
        VStack(spacing: 0) {
            Picker("Scope", selection: $scope) {
                ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)

            if totalInPeriod > 0 {
                GroceryProgressBar(checked: checkedInPeriod, total: totalInPeriod)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }

            WeekNavBar(plan: plan)

            if scope == .day {
                DayStrip(plan: plan, selectedDayKey: $selectedDayKey)
                    .padding(.bottom, 6)
            }

            Divider()

            content
        }
    }

    private var completionBanner: some View {
        Text("All done! 🎉")
            .font(.headline)
            .foregroundStyle(Color.white)
            .padding(.vertical, 10)
            .padding(.horizontal, 20)
            .background(
                Capsule().fill(Color.accentColor)
            )
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .allowsHitTesting(false)
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
                        ForEach(orderedItems(section.items)) { item in
                            let key = "\(periodKey)|\(item.stableKey)"
                            GroceryCheckRow(
                                text: item.displayString,
                                detail: item.sources.joined(separator: ", "),
                                icon: GroceryItemIconResolver.icon(for: item.name),
                                checked: model.isChecked(key)
                            ) {
                                toggle(key)
                            }
                            .tornEdgeCardRow()
                        }
                    } header: {
                        sectionHeader(section.category.displayName)
                    }
                }

                if !manualForPeriod.isEmpty {
                    Section {
                        ForEach(orderedManual(manualForPeriod)) { item in
                            GroceryCheckRow(
                                text: item.name,
                                detail: nil,
                                icon: GroceryItemIconResolver.icon(for: item.name),
                                checked: model.isChecked(item.checkKey)
                            ) {
                                toggle(item.checkKey)
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

    // MARK: - Progress & completion

    /// Every checkable key in the current period — recipe-derived lines plus
    /// hand-added items — the denominator for progress and completion.
    private var allCheckKeys: [String] {
        let recipeKeys = sections.flatMap { $0.items.map { "\(periodKey)|\($0.stableKey)" } }
        let manualKeys = manualForPeriod.map(\.checkKey)
        return recipeKeys + manualKeys
    }

    private var totalInPeriod: Int { allCheckKeys.count }

    private var checkedInPeriod: Int {
        allCheckKeys.reduce(0) { $0 + (model.isChecked($1) ? 1 : 0) }
    }

    private var isComplete: Bool {
        totalInPeriod > 0 && checkedInPeriod == totalInPeriod
    }

    /// Identity of *this* completed list. Includes the period and the full sorted
    /// key set, so it stays constant across an uncheck/recheck of the same final
    /// item but changes the moment the list is repopulated for a new trip.
    private var completionSignature: String {
        periodKey + "#" + allCheckKeys.sorted().joined(separator: ",")
    }

    // MARK: - Interaction

    /// Toggle a checkmark with the playful feedback: a distinct haptic for
    /// check vs. uncheck, and an animated settle (checked items sink to the
    /// bottom of their section). Reduce Motion drops the animation but keeps
    /// the haptic.
    private func toggle(_ key: String) {
        let willCheck = !model.isChecked(key)
        fireToggleHaptic(checking: willCheck)
        if reduceMotion {
            model.toggle(key)
        } else {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) {
                model.toggle(key)
            }
        }
    }

    private func fireToggleHaptic(checking: Bool) {
        // A crisper tap on check, a softer one on uncheck, so the two directions
        // feel deliberately different in the hand.
        let generator = UIImpactFeedbackGenerator(style: checking ? .medium : .soft)
        generator.impactOccurred(intensity: checking ? 1.0 : 0.7)
    }

    /// Fire confetti + banner + success haptic once per distinct completion.
    private func celebrateCompletion() {
        guard celebratedSignature != completionSignature else { return }
        celebratedSignature = completionSignature

        UINotificationFeedbackGenerator().notificationOccurred(.success)

        if !reduceMotion {
            confettiTrigger += 1
        }

        bannerDismissTask?.cancel()
        withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8)) {
            showDoneBanner = true
        }
        bannerDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_900_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.4)) {
                showDoneBanner = false
            }
        }
    }

    // MARK: - Ordering (checked items settle to the bottom)

    /// Unchecked items first (alphabetized), checked items sink below. Combined
    /// with the animated `toggle`, the List animates the move.
    private func orderedItems(_ items: [GroceryLineItem]) -> [GroceryLineItem] {
        items.sorted { lhs, rhs in
            let lc = model.isChecked("\(periodKey)|\(lhs.stableKey)")
            let rc = model.isChecked("\(periodKey)|\(rhs.stableKey)")
            if lc != rc { return !lc }
            return lhs.name.lowercased() < rhs.name.lowercased()
        }
    }

    private func orderedManual(_ items: [GroceryManualItem]) -> [GroceryManualItem] {
        items.sorted { lhs, rhs in
            let lc = model.isChecked(lhs.checkKey)
            let rc = model.isChecked(rhs.checkKey)
            if lc != rc { return !lc }
            return lhs.addedAt < rhs.addedAt
        }
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

    // MARK: - Share today's list

    /// Today's recipe-derived grocery items, EXCLUDING checked-off (already-bought)
    /// items. Always keyed to the real calendar day (`dayKey(for: Date())`),
    /// independent of the Day/Week scope the user is currently viewing. Reuses the
    /// same derivation as the list: entries → recipes → GroceryAggregator, and the
    /// same period-scoped checked-state key ("day:<todayKey>|<stableKey>").
    private var todayPeriodKey: String { "day:\(plan.dayKey(for: Date()))" }

    private var todayUncheckedItems: [GroceryLineItem] {
        let todayKey = plan.dayKey(for: Date())
        let entries = mealStore.entries(on: todayKey)
        let byId = Dictionary(jobs.recipes.map { ($0.recipeId, $0) }, uniquingKeysWith: { first, _ in first })
        let recipes = entries.compactMap { byId[$0.recipeId] }
        let items = GroceryAggregator.aggregate(recipes: recipes)
        return items.filter { !model.isChecked("\(todayPeriodKey)|\($0.stableKey)") }
    }

    /// Today's hand-added ("Added by you") item names, excluding checked-off ones.
    private var todayUncheckedManualNames: [String] {
        model.manualItems(inPeriod: todayPeriodKey)
            .filter { !model.isChecked($0.checkKey) }
            .map(\.name)
    }

    /// Enabled when there's anything to share for today — a recipe-derived item OR
    /// a hand-added one — after excluding checked-off (already-bought) items.
    private var canShareToday: Bool {
        !todayUncheckedItems.isEmpty || !todayUncheckedManualNames.isEmpty
    }

    /// The plain-text list handed to the native share sheet.
    private var todayShareText: String {
        GroceryShareText.build(
            items: todayUncheckedItems,
            for: Date(),
            manualItems: todayUncheckedManualNames
        )
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

// MARK: - Item icon (ingredient photo or emoji + checked-state affordance)

/// The leading glyph on a grocery row: a bundled ingredient photo when we have
/// one for the item, otherwise its category emoji. Toggling checked keeps the
/// icon visible (dimmed) and lays a small checkmark badge over it, so the tap
/// affordance survives while the icon still tells you what the item is. Occupies
/// the same 30×30 footprint as the old circle so rows neither shift horizontally
/// nor grow taller.
private struct GroceryItemIconView: View {
    let icon: GroceryItemIcon
    let checked: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        IngredientIconGlyph(icon: icon, size: 30)
            .opacity(checked ? 0.4 : 1.0)
            .overlay(alignment: .bottomTrailing) {
                if checked {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.secondaryAccent)
                        .background(Circle().fill(Color.appBackground))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            // A quick pop as the check lands, matching the old circle's bounce.
            .scaleEffect(checked ? 1.12 : 1.0)
            .animation(
                reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.5),
                value: checked
            )
            .accessibilityHidden(true)
    }
}

// MARK: - Checkable row

private struct GroceryCheckRow: View {
    let text: String
    let detail: String?
    let icon: GroceryItemIcon
    let checked: Bool
    let onToggle: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                GroceryItemIconView(icon: icon, checked: checked)

                VStack(alignment: .leading, spacing: 2) {
                    StrikeThroughText(
                        text: text,
                        struck: checked,
                        animate: !reduceMotion
                    )
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
            // Dim the whole row as it settles into the "got it" state.
            .opacity(checked ? 0.55 : 1.0)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: checked)
        }
        .buttonStyle(.plain)
    }
}

/// A line of text with a strike-through that *draws across* the word when
/// `struck` becomes true (instead of the instant native `.strikethrough`). The
/// bar is a rule overlaid on the text, its width measured from the text itself
/// and animated from 0 → full. Reduce Motion snaps straight to full.
private struct StrikeThroughText: View {
    let text: String
    let struck: Bool
    let animate: Bool

    @State private var textWidth: CGFloat = 0

    var body: some View {
        Text(text)
            .font(.body)
            .foregroundStyle(struck ? Color.textSecondary : Color.textPrimary)
            .animation(animate ? .easeInOut(duration: 0.3) : nil, value: struck)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { textWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, w in textWidth = w }
                }
            )
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Color.textSecondary)
                    .frame(width: struck ? textWidth : 0, height: 1.5)
                    .animation(
                        animate ? .easeInOut(duration: 0.32) : nil,
                        value: struck
                    )
            }
    }
}

/// Thin animated progress bar for the current period's list, filled in the sage
/// accent. The fill springs to its new width whenever the checked count changes.
private struct GroceryProgressBar: View {
    let checked: Int
    let total: Int

    private var fraction: CGFloat {
        total > 0 ? CGFloat(checked) / CGFloat(total) : 0
    }

    private var remaining: Int { max(0, total - checked) }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(remaining == 0
                     ? "All items checked off"
                     : "\(remaining) of \(total) item\(total == 1 ? "" : "s") left")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.textSecondary)
                Spacer()
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.textSecondary.opacity(0.18))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(0, geo.size.width * fraction))
                }
            }
            .frame(height: 6)
            .animation(.spring(response: 0.5, dampingFraction: 0.78), value: fraction)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Shopping progress")
        .accessibilityValue("\(checked) of \(total) items checked off")
    }
}

#Preview {
    NavigationStack {
        GroceryListView(jobs: PendingJobsModel(provider: MockRecipeProvider()))
    }
}
