//
//  GroceryListView.swift
//  RecipeApp
//
//  The Grocery segment of the Kitchen tab: a shopping list derived live from the
//  Meal Plan for a chosen period (a single day or the whole visible week).
//  Nothing about the ingredient list is stored — it is recomputed from meal-plan
//  state on every render, so it always reflects the current plan. Only two things
//  persist: which items are checked off, and hand-added manual items — both in
//  `GroceryListModel` / `GroceryCheckStore`.
//
//  Chrome lives in the parent `KitchenTabView` (the serif header with the share +
//  add buttons, and the single Grocery/Pantry segmented control). This view adds
//  the 7-day strip, a caption row with the "Show whole week" toggle, and the
//  list itself. Day vs. week is a single boolean (`showWholeWeek`) rather than a
//  second segmented control. The header's share/add buttons drive this view via
//  the `sharePresented` / `addPresented` bindings.
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

    /// When true (shown inside KitchenTabView), suppress this view's own title +
    /// toolbar so the container supplies them. Presentation only.
    private let embedded: Bool

    /// Header-button triggers, owned by the container. `addPresented` drives the
    /// "add manual item" alert; `sharePresented` drives the share sheet.
    @Binding private var addPresented: Bool
    @Binding private var sharePresented: Bool
    /// Grocery empty-state "Plan a meal" → switch to the Meal Plan tab.
    private let onPlanMeal: () -> Void

    init(jobs: PendingJobsModel,
         userScope: String? = nil,
         sync: SyncCoordinator? = nil,
         embedded: Bool = false,
         addPresented: Binding<Bool> = .constant(false),
         sharePresented: Binding<Bool> = .constant(false),
         onPlanMeal: @escaping () -> Void = {}) {
        self.jobs = jobs
        _plan = StateObject(wrappedValue: MealPlanModel(userScope: userScope, sync: sync))
        _model = StateObject(wrappedValue: GroceryListModel(userScope: userScope, sync: sync))
        self.mealStore = MealPlanStore(userScope: userScope)
        self.embedded = embedded
        _addPresented = addPresented
        _sharePresented = sharePresented
        self.onPlanMeal = onPlanMeal
    }

    /// Day vs. whole-week, toggled by the "Show whole week" caption button.
    @State private var showWholeWeek = false
    /// The day selected in Day scope, as a "yyyy-MM-dd" key. Always one of the
    /// visible week's days (kept in range by `syncSelectedDay`).
    @State private var selectedDayKey: String = ""
    @State private var newItemText = ""

    // Celebration state. `confettiTrigger` fires a burst on increment;
    // `celebratedSignature` records the exact set of items whose completion was
    // already celebrated, so unchecking + rechecking the same final item does not
    // re-fire — only a meaningfully different list produces a fresh celebration.
    @State private var confettiTrigger = 0
    @State private var showDoneBanner = false
    @State private var celebratedSignature: String?
    @State private var bannerDismissTask: Task<Void, Never>?

    /// The active period scope, derived from the whole-week toggle.
    private enum Scope { case day, week }
    private var scope: Scope { showWholeWeek ? .week : .day }

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
        .navigationTitle("Grocery List", active: !embedded)
        .navigationBarTitleDisplayMode(.inline)
        // Standalone (non-embedded) chrome only — inside the Kitchen tab the
        // container supplies the header + its buttons instead.
        .toolbar {
            if !embedded {
                ToolbarItem(placement: .topBarLeading) {
                    Button { sharePresented = true } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(!canShareToday)
                    .accessibilityLabel("Share today's grocery list")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { addPresented = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add item")
                }
            }
        }
        .sheet(isPresented: $sharePresented) {
            ActivityView(items: [todayShareText])
        }
        .onAppear(perform: syncSelectedDay)
        .onChange(of: plan.weekStart) { _, _ in syncSelectedDay() }
        .onChange(of: isComplete) { _, complete in
            if complete { celebrateCompletion() }
        }
        .alert("Add item", isPresented: $addPresented) {
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
            if scope == .day {
                DayStrip(plan: plan, selectedDayKey: $selectedDayKey)
                    .padding(.bottom, 4)
            }

            captionRow
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            if totalInPeriod > 0 {
                GroceryProgressBar(checked: checkedInPeriod, total: totalInPeriod)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }

            Divider()

            content
        }
    }

    /// Selected date on the left, whole-week toggle on the right.
    private var captionRow: some View {
        HStack {
            Text(periodLabel)
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showWholeWeek.toggle() }
            } label: {
                Text(showWholeWeek ? "Show single day" : "Show whole week")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        }
    }

    private var completionBanner: some View {
        Label("All done!", systemImage: "checkmark.circle.fill")
            .font(.headline)
            .foregroundStyle(Color.white)
            .padding(.vertical, 10)
            .padding(.horizontal, 20)
            .background(Capsule().fill(Color.accentColor))
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
                            .cardRow(bordered: false)
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
                            .cardRow(bordered: false)
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
                            .cardRow(bordered: false)
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
            .contentMargins(.bottom, Theme.Spacing.tabBarClearance, for: .scrollContent)
        }
    }

    /// Redesigned empty state: a cream circle with a sage symbol (swap the circle
    /// for a sticker image later), a serif title, one line of guidance, and a sage
    /// "Plan a meal" button that jumps to the Meal Plan tab.
    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.creamTint)
                    .frame(width: 72, height: 72)
                // Swappable slot: replace this SF Symbol with a sticker image later.
                Image(systemName: "cart")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(Color.accentColor)
            }

            Text("Nothing to shop for")
                .font(.editorialTitle(size: 24, relativeTo: .title2))
                .foregroundStyle(Color.textPrimary)

            Text("Plan a meal for this day and its ingredients will land here.")
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 40)

            Button(action: onPlanMeal) {
                Text("Plan a meal")
                    .font(.headline)
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, Theme.Spacing.tabBarClearance)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.5)
            .foregroundStyle(Color.textSecondary)
    }

    // MARK: - Period label

    /// The caption-row label: the selected day, or the visible week's range.
    private var periodLabel: String {
        let f = DateFormatter()
        switch scope {
        case .day:
            let date = plan.weekDays.first { plan.dayKey(for: $0) == selectedDayKey }
            f.dateFormat = "EEEE, MMM d"
            return date.map { f.string(from: $0) } ?? ""
        case .week:
            guard let first = plan.weekDays.first, let last = plan.weekDays.last else { return "" }
            f.dateFormat = "MMM d"
            let start = f.string(from: first)
            f.dateFormat = "MMM d"
            return "\(start) – \(f.string(from: last))"
        }
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

    /// Today's recipe-derived grocery items, EXCLUDING checked-off items. Always
    /// keyed to the real calendar day, independent of the Day/Week scope shown.
    private var todayPeriodKey: String { "day:\(plan.dayKey(for: Date()))" }

    private var todayUncheckedItems: [GroceryLineItem] {
        let todayKey = plan.dayKey(for: Date())
        let entries = mealStore.entries(on: todayKey)
        let byId = Dictionary(jobs.recipes.map { ($0.recipeId, $0) }, uniquingKeysWith: { first, _ in first })
        let recipes = entries.compactMap { byId[$0.recipeId] }
        let items = GroceryAggregator.aggregate(recipes: recipes)
        return items.filter { !model.isChecked("\(todayPeriodKey)|\($0.stableKey)") }
    }

    private var todayUncheckedManualNames: [String] {
        model.manualItems(inPeriod: todayPeriodKey)
            .filter { !model.isChecked($0.checkKey) }
            .map(\.name)
    }

    private var canShareToday: Bool {
        !todayUncheckedItems.isEmpty || !todayUncheckedManualNames.isEmpty
    }

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

// MARK: - Day strip (pick one of the week's days)

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
                    .fill(isSelected ? Color.accentColor : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isToday && !isSelected ? Color.accentColor : Color.clear,
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

// MARK: - Item icon (ingredient photo + checked-state affordance)

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
                        .foregroundStyle(Color.accentColor)
                        .background(Circle().fill(Color.appBackground))
                        .transition(.scale.combined(with: .opacity))
                }
            }
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
            .opacity(checked ? 0.55 : 1.0)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: checked)
        }
        .buttonStyle(.plain)
    }
}

/// A line of text with a strike-through that draws across the word when `struck`
/// becomes true. Reduce Motion snaps straight to full.
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

/// Thin animated progress bar for the current period's list, filled in sage.
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
