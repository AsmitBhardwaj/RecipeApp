//
//  KitchenView.swift
//  RecipeApp
//
//  The Kitchen tab: a plain list of what the user has on hand (their "pantry").
//  Distilled from the "Added by you" portion of `GroceryListView` — same card /
//  list styling and the same add-field + swipe-to-delete affordances — but with
//  everything shopping-specific removed: no meal-plan derivation, no periods, no
//  checked/bought state. A pantry item isn't ticked off; removing it IS the
//  "used it up" action.
//
//  Names are stored verbatim (see `PantryModel.add`); any normalization for the
//  later recipe-suggestion feature happens at match time, not here.
//

import SwiftUI
import RecipeKit

struct KitchenView: View {
    @StateObject private var model: PantryModel
    /// Recipe suggestions driven by the current pantry (PANTRY_SCOPE.md §4).
    @StateObject private var suggestions = PantrySuggestionsModel()
    /// The app's single CookbooksModel, threaded down from MainTabView (the same
    /// instance the Recipes tab uses) so "add to cookbook" from the suggestion
    /// detail sheet writes to the shared state — no second instance, no
    /// cross-tab desync.
    @ObservedObject private var cookbooks: CookbooksModel

    /// Tapping a suggestion opens it in a detail sheet (the Kitchen tab has its
    /// own NavigationStack; a sheet keeps this self-contained across the segment
    /// picker without touching the Grocery segment's navigation).
    @State private var selectedRecipe: Recipe?

    private let userScope: String?
    private let sync: SyncCoordinator?

    /// When true (shown inside KitchenTabView), suppress this view's own
    /// principal title + navigationTitle so the container supplies a single
    /// consistent "Kitchen" title. Presentation only — logic/state unchanged.
    private let embedded: Bool

    /// The "add pantry item" sheet trigger. Owned by the container's header add
    /// button when embedded; the standalone toolbar button drives it otherwise.
    @Binding private var addPresented: Bool

    init(cookbooks: CookbooksModel, userScope: String? = nil, sync: SyncCoordinator? = nil,
         embedded: Bool = false, addPresented: Binding<Bool> = .constant(false)) {
        _model = StateObject(wrappedValue: PantryModel(userScope: userScope, sync: sync))
        _cookbooks = ObservedObject(wrappedValue: cookbooks)
        self.userScope = userScope
        self.sync = sync
        self.embedded = embedded
        _addPresented = addPresented
    }

    var body: some View {
        content
            .foregroundStyle(Color.textPrimary)
            .appBackground()
            .navigationTitle("Kitchen", active: !embedded)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !embedded {
                    ToolbarItem(placement: .principal) {
                        Text("Kitchen")
                            .font(.editorialTitle(size: 22))
                            .foregroundStyle(Color.textPrimary)
                    }
                }
                if !embedded {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            addPresented = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Add item")
                    }
                }
            }
            // Custom bottom sheet (matches the app card system + adds ingredient
            // type-ahead) in place of the old system alert. Add path is unchanged:
            // it still calls PantryModel.add with the submitted text.
            .addToKitchenSheet(isPresented: $addPresented) { name in
                model.add(name: name)
            }
            // Refresh on appear so pantry changes made elsewhere (or in a previous
            // session) show without a manual pull-to-refresh. Immediate (no
            // debounce). Matches against the LOCAL names so results track what's
            // on screen without waiting for the pantry to sync.
            .task {
                guard let sync else { return }
                suggestions.refresh(pantryNames: model.items.map(\.name), via: sync)
            }
            // Pantry edits refresh on a DEBOUNCE, not per-add: the add sheet's
            // dismissal (Cancel or post-Add close) is the single trigger, and a
            // burst of adds within the window collapses into one call. Both the
            // "Cook with what you have" matches and the "Ideas to try" generated
            // list come from the same endpoint response, so they share this one
            // trigger — there is no separate local data path to recompute.
            .onChange(of: addPresented) { _, isShowing in
                guard !isShowing, let sync else { return }
                suggestions.refresh(pantryNames: model.items.map(\.name), via: sync, debounce: .seconds(1.5))
            }
            .sheet(item: $selectedRecipe) { recipe in
                NavigationStack {
                    RecipeDetailView(recipe: recipe, cookbooks: cookbooks, userScope: userScope)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                pantrySection
                suggestionsContent
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, Theme.Spacing.tabBarClearance)
        }
    }

    // MARK: - Pantry chips ("In your kitchen")

    private var pantrySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("In your kitchen")

            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(model.items) { item in
                    PantryChip(name: Self.displayName(item.name)) {
                        model.remove(item)
                        // Removals are pantry edits too — refresh on the same
                        // debounce as adds so rapid deletes coalesce.
                        if let sync {
                            suggestions.refresh(pantryNames: model.items.map(\.name), via: sync, debounce: .seconds(1.5))
                        }
                    }
                }
                AddPantryChip { addPresented = true }
            }

            if model.items.isEmpty {
                Text("Add what's in your kitchen so we can suggest recipes using it.")
                    .font(.footnote)
                    .foregroundStyle(Color.textSecondary)
            }
        }
    }

    /// Sentence-case a stored pantry name for DISPLAY only (stored value is
    /// unchanged): first letter upper, remainder lower — so "avocado", "AVOCADO"
    /// and "Avocado" all render as "Avocado".
    static func displayName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return trimmed }
        return first.uppercased() + trimmed.dropFirst().lowercased()
    }

    // MARK: - Suggestions

    /// Cache matches to display, ranked client-side (coverage desc, tie-break by
    /// matched count; drop < 20% coverage unless that leaves fewer than 3).
    private var rankedMatches: [PantrySuggestion] {
        PantrySuggestionRanking.rank(suggestions.matches)
    }

    @ViewBuilder
    private var suggestionsContent: some View {
        if suggestions.isInitialLoading {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("Suggestions")
                HStack(spacing: 10) {
                    ProgressView().tint(Color.accentColor)
                    Text("Finding suggestions…")
                        .font(.subheadline)
                        .foregroundStyle(Color.textSecondary)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            }
        } else {
            if !rankedMatches.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        sectionHeader("Cook with what you have")
                        if suggestions.isRefreshing {
                            ProgressView().controlSize(.mini).tint(Color.accentColor)
                        }
                    }
                    Text("Closest matches first")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                    ForEach(rankedMatches) { suggestionRow($0) }
                }
            }
            if !suggestions.generated.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        sectionHeader("Ideas to try")
                        if suggestions.isRefreshing {
                            ProgressView().controlSize(.mini).tint(Color.accentColor)
                        }
                    }
                    ForEach(suggestions.generated) { suggestionRow($0) }
                }
            }
        }
    }

    private func suggestionRow(_ suggestion: PantrySuggestion) -> some View {
        Button {
            selectedRecipe = suggestion.recipe
        } label: {
            SuggestionRow(suggestion: suggestion)
                .card(bordered: false)
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.5)
            .foregroundStyle(Color.textSecondary)
    }
}

// MARK: - Pantry chip (cream, name only — no emoji; long-press to remove)

private struct PantryChip: View {
    let name: String
    let onRemove: () -> Void

    var body: some View {
        Text(name)
            .font(.subheadline)
            .foregroundStyle(Color.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(Capsule().fill(Color.creamTint))  // 40pt high → 20pt radius
            .contextMenu {
                Button(role: .destructive, action: onRemove) {
                    Label("Remove", systemImage: "trash")
                }
            }
    }
}

/// The trailing outlined "+ Add" chip that opens the add-item sheet.
private struct AddPantryChip: View {
    let onAdd: () -> Void

    var body: some View {
        Button(action: onAdd) {
            Label("Add", systemImage: "plus")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 14)
                .frame(height: 40)
                .overlay(Capsule().strokeBorder(Color.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add pantry item")
    }
}

// MARK: - Suggestion row (photo + serif name + coverage bar + AI-suggested pill)

private struct SuggestionRow: View {
    let suggestion: PantrySuggestion

    private var fraction: CGFloat {
        let total = suggestion.match.totalCount
        return total > 0 ? CGFloat(suggestion.match.haveCount) / CGFloat(total) : 0
    }

    var body: some View {
        HStack(spacing: 14) {
            RecipeImageView(
                imageUrl: suggestion.recipe.imageUrl,
                fallbackSeed: suggestion.recipe.recipeId,
                fallbackTitle: suggestion.recipe.title,
                placeholderSymbolSize: 22
            )
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(suggestion.recipe.title)
                    .font(.editorialTitle(size: 16, relativeTo: .body))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Text("\(suggestion.match.haveCount) of \(suggestion.match.totalCount) ingredients")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                    Spacer(minLength: 0)
                    if suggestion.recipe.isGenerated {
                        AISuggestedPill()
                    }
                }

                CoverageBar(fraction: fraction)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// A thin coverage bar: sage fill over a hairline track, 4pt tall.
private struct CoverageBar: View {
    let fraction: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.hairline)
                Capsule().fill(Color.accentColor)
                    .frame(width: max(0, geo.size.width * fraction))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// The "AI suggested" marker: a small cream pill with a sparkle symbol,
/// replacing the previous inline italic text.
private struct AISuggestedPill: View {
    var body: some View {
        Label("AI suggested", systemImage: "sparkles")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.creamTint))
    }
}

#Preview {
    NavigationStack {
        KitchenView(cookbooks: CookbooksModel())
    }
}
