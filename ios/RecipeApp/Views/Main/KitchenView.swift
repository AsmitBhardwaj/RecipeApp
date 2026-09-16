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

    @State private var showingAddItem = false
    @State private var newItemText = ""
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

    init(cookbooks: CookbooksModel, userScope: String? = nil, sync: SyncCoordinator? = nil, embedded: Bool = false) {
        _model = StateObject(wrappedValue: PantryModel(userScope: userScope, sync: sync))
        _cookbooks = ObservedObject(wrappedValue: cookbooks)
        self.userScope = userScope
        self.sync = sync
        self.embedded = embedded
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
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddItem = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add item")
                }
            }
            .alert("Add to kitchen", isPresented: $showingAddItem) {
                TextField("e.g. olive oil", text: $newItemText)
                Button("Add") {
                    model.add(name: newItemText)
                    newItemText = ""
                }
                Button("Cancel", role: .cancel) { newItemText = "" }
            } message: {
                Text("Add something you have on hand.")
            }
            // Reload suggestions whenever the pantry changes (add/remove). Matches
            // against the LOCAL names so results track what's on screen without
            // waiting for the pantry to sync.
            .task(id: model.items) {
                guard let sync else { return }
                await suggestions.load(pantryNames: model.items.map(\.name), via: sync)
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
                        .tornEdgeCardRow(bordered: false)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                model.remove(item)
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
    /// generation-fallback `generated` ideas (each badged "Suggested recipe").
    @ViewBuilder
    private var suggestionsSections: some View {
        if suggestions.isInitialLoading {
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Finding recipes you can make…")
                        .font(.subheadline)
                        .foregroundStyle(Color.textSecondary)
                }
                .padding(.vertical, 4)
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
                    sectionHeader("Ideas to try")
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
        .tornEdgeCardRow(bordered: false)
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

// MARK: - Suggestion row (image + title + match chip + "Suggested recipe" badge)

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

            VStack(alignment: .leading, spacing: 5) {
                Text(suggestion.recipe.title)
                    .font(.appRowTitle)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    MatchContextBadge(match: suggestion.match)
                    // GeneratedBadge is revived ONLY here, and only for the
                    // generation-fallback recipes, labeled "Suggested recipe"
                    // (PANTRY_SCOPE.md §4). Cache matches carry no such badge.
                    if suggestion.recipe.isGenerated {
                        GeneratedBadge(label: "Suggested recipe")
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

#Preview {
    NavigationStack {
        KitchenView(cookbooks: CookbooksModel())
    }
}
