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
        if model.items.isEmpty {
            emptyState
        } else {
            List {
                Section {
                    ForEach(model.items) { item in
                        KitchenRow(
                            text: item.name,
                            icon: GroceryItemIconResolver.icon(for: item.name)
                        )
                        .cardRow(bordered: false)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                model.remove(item)
                                // Removals are pantry edits too — refresh on the
                                // same debounce as adds so rapid deletes coalesce.
                                if let sync {
                                    suggestions.refresh(pantryNames: model.items.map(\.name), via: sync, debounce: .seconds(1.5))
                                }
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    sectionHeader("In your kitchen")
                }

                suggestionsSections
            }
            .listStyle(.plain)
        }
    }

    /// Recipe suggestions from the current pantry: cache `matches` first, then the
    /// generation-fallback `generated` ideas (each carrying an inline "AI
    /// suggested" note on its metadata line).
    @ViewBuilder
    private var suggestionsSections: some View {
        if suggestions.isInitialLoading {
            Section {
                HStack(spacing: 10) {
                    // Tint with the sage accent instead of the system default gray.
                    ProgressView()
                        .tint(Color.accentColor)
                    // Generic, persistent label: results resolve into one OR two
                    // sections ("Cook with what you have" / "Ideas to try"), so a
                    // single-list phrasing would over-promise. Matches the
                    // "Suggestions" header above.
                    Text("Finding suggestions…")
                        .font(.subheadline)
                        .foregroundStyle(Color.textSecondary)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                // Same card background / corner radius as the suggestion + kitchen
                // rows, so the loading state reads as part of the Kitchen tab
                // rather than a plain rect.
                .cardRow(bordered: false)
            } header: {
                sectionHeader("Suggestions")
            }
        } else {
            if !suggestions.matches.isEmpty {
                Section {
                    ForEach(suggestions.matches) { suggestionRow($0) }
                } header: {
                    sectionHeader("Cook with what you have")
                }
            }
            if !suggestions.generated.isEmpty {
                Section {
                    ForEach(suggestions.generated) { suggestionRow($0) }
                } header: {
                    HStack(spacing: 8) {
                        sectionHeader("Ideas to try")
                        // Lightweight in-section indicator while a debounced
                        // refresh is in flight — the existing ideas stay visible
                        // and tappable, so pantry edits still feel responsive.
                        if suggestions.isRefreshing {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(Color.accentColor)
                        }
                    }
                }
            }
        }
    }

    private func suggestionRow(_ suggestion: PantrySuggestion) -> some View {
        Button {
            selectedRecipe = suggestion.recipe
        } label: {
            SuggestionRow(suggestion: suggestion)
        }
        .buttonStyle(.plain)
        .cardRow(bordered: false)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Your kitchen is empty", systemImage: "refrigerator")
        } description: {
            Text("Add what's in your kitchen so we can suggest recipes using it")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.5)
            .foregroundStyle(Color.textSecondary)
    }
}

// MARK: - Row (ingredient glyph + name; no checked-state affordance)

private struct KitchenRow: View {
    let text: String
    let icon: GroceryItemIcon

    var body: some View {
        HStack(spacing: 12) {
            IngredientIconGlyph(icon: icon, size: 30)
                .accessibilityHidden(true)

            Text(text)
                .font(.body)
                .foregroundStyle(Color.textPrimary)

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Suggestion row (image + title + inline match/AI metadata line)

private struct SuggestionRow: View {
    let suggestion: PantrySuggestion

    var body: some View {
        HStack(spacing: 14) {
            RecipeImageView(
                imageUrl: suggestion.recipe.imageUrl,
                fallbackSeed: suggestion.recipe.recipeId,
                fallbackTitle: suggestion.recipe.title,
                placeholderSymbolSize: 20
            )
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // Title + a single muted metadata line (no pills). Spacing is tight
            // now that the old two-pill row collapsed to one line of text.
            VStack(alignment: .leading, spacing: 3) {
                Text(suggestion.recipe.title)
                    .font(.appRowTitle)
                    .lineLimit(2)

                metadataLine
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// One muted, container-less line beneath the title: the ingredient fraction,
    /// and — only for generation-fallback results (same gate as before) — a
    /// middle-dot, a small sparkle, and an italic "AI suggested". Cache matches
    /// (e.g. "Cook with what you have") show only the fraction. A single
    /// `textSecondary` from the existing palette carries the whole line.
    private var metadataLine: some View {
        var text = Text(suggestion.match.ingredientSummary)
        if suggestion.recipe.isGenerated {
            text = text
                + Text("  ·  ")
                + Text(Image(systemName: "sparkles"))
                + Text(" AI suggested").italic()
        }
        return text
            .font(.caption)
            .foregroundStyle(Color.textSecondary)
            .lineLimit(1)
    }
}

#Preview {
    NavigationStack {
        KitchenView(cookbooks: CookbooksModel())
    }
}
