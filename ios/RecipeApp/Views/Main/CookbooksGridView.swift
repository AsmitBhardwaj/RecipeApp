//
//  CookbooksGridView.swift
//  RecipeApp
//
//  The Recipes-tab home: a large serif header (Account + Add buttons), a
//  horizontal cookbook filter chip row ("All · N", one chip per cookbook, and a
//  "+ New cookbook" text button), and a 2-column photo grid of recipes. "All" is
//  selected by default; picking a cookbook filters the grid in place (no push).
//  The final grid cell is an "Add a recipe" tile.
//
//  This view also owns the tab-level concerns: loading/failed states, the
//  add-recipe / Account affordances, and — so a share is acknowledged the moment
//  the user lands here (CLAUDE.md §6) — the in-flight (processing) and failed job
//  cards, shown above the grid.
//

import SwiftUI
import RecipeKit

struct CookbooksGridView: View {
    @ObservedObject var jobs: PendingJobsModel
    @ObservedObject var cookbooks: CookbooksModel
    /// Account scope, threaded to Recipe Detail for the Cook Mode timer store.
    var userScope: String? = nil

    @State private var showingAdd = false
    @State private var showingAccount = false
    @State private var showingNewCookbook = false
    @State private var newCookbookName = ""
    /// The failed job the user is pasting recipe text for (drives the sheet).
    @State private var pasteTarget: PendingJobsModel.FailedJob?
    /// Which cookbook (or All) filters the grid. Defaults to All.
    @State private var filter: RecipeFilter = .all

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        ZStack {
            switch jobs.loadState {
            case .loading:
                ProgressView("Loading recipes…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't load recipes", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again") { Task { await jobs.load() } }
                }
            case .loaded:
                content
            }
        }
        .foregroundStyle(Color.textPrimary)
        .appBackground()
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingAdd) {
            AddRecipeView(jobs: jobs)
        }
        .sheet(item: $pasteTarget) { failedJob in
            PasteRecipeTextView(jobs: jobs, failedJob: failedJob)
        }
        .sheet(isPresented: $showingAccount) {
            NavigationStack {
                AccountView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingAccount = false }
                        }
                    }
            }
        }
        .alert("New Cookbook", isPresented: $showingNewCookbook) {
            TextField("Name", text: $newCookbookName)
            Button("Create") {
                cookbooks.createCookbook(named: newCookbookName)
                newCookbookName = ""
            }
            Button("Cancel", role: .cancel) { newCookbookName = "" }
        } message: {
            Text("Name your new cookbook.")
        }
        // Recipe detail push (from any recipe tile).
        .navigationDestination(for: Recipe.self) { recipe in
            RecipeDetailView(recipe: recipe, cookbooks: cookbooks, userScope: userScope)
        }
        .task { await jobs.load() }
    }

    // MARK: - Header (shared across content states)

    private var header: some View {
        ScreenHeader("Recipes") {
            CircleHeaderButton(systemImage: "person.crop.circle",
                               accessibilityLabel: "Account") { showingAccount = true }
            CircleHeaderButton(systemImage: "plus", primary: true,
                               accessibilityLabel: "Add recipe") { showingAdd = true }
        }
    }

    // MARK: - Content

    /// Fresh account: nothing saved and nothing in flight → show the first-run
    /// empty state (under the header) instead of an empty grid.
    private var isLibraryEmpty: Bool {
        jobs.recipes.isEmpty && jobs.pending.isEmpty && jobs.failed.isEmpty && cookbooks.cookbooks.isEmpty
    }

    /// Recipes shown for the current filter.
    private var displayedRecipes: [Recipe] {
        switch filter {
        case .all:
            return jobs.recipes
        case .cookbook(let id):
            let ids = cookbooks.recipeIds(in: id)
            return jobs.recipes.filter { ids.contains($0.recipeId) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLibraryEmpty {
            ScrollView {
                header
                EmptyLibraryView()
            }
        } else {
            gridContent
        }
    }

    private var gridContent: some View {
        ScrollView {
            LazyVStack(spacing: 14, pinnedViews: []) {
                header

                // In-flight / failed job cards first, so a just-submitted share is
                // acknowledged here on the tab home (shown across all filters).
                ForEach(jobs.failed) { failedJob in
                    FailedJobCardView(
                        job: failedJob,
                        onDismiss: { jobs.dismissFailed(jobId: failedJob.jobId) },
                        onPasteText: failedJob.canPasteText ? { pasteTarget = failedJob } : nil
                    )
                    .card()
                    .padding(.horizontal, 16)
                }
                ForEach(jobs.pending) { pendingJob in
                    ProcessingCardView(job: pendingJob)
                        .card()
                        .padding(.horizontal, 16)
                }

                CookbookChipRow(
                    allCount: jobs.recipes.count,
                    cookbooks: cookbooks,
                    filter: $filter,
                    onNewCookbook: { showingNewCookbook = true }
                )

                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(displayedRecipes) { recipe in
                        NavigationLink(value: recipe) {
                            RecipePhotoCard(recipe: recipe)
                        }
                        .buttonStyle(.plain)
                    }
                    // Trailing "Add a recipe" tile, always last.
                    AddRecipeTile { showingAdd = true }
                }
                .padding(.horizontal, 16)
                .padding(.top, 2)
            }
            .padding(.bottom, Theme.Spacing.tabBarClearance)  // clear the floating tab bar
        }
    }
}

// MARK: - Filter

/// The Recipes-tab grid filter: everything, or one cookbook's members.
private enum RecipeFilter: Hashable {
    case all
    case cookbook(String)  // cookbook id
}

// MARK: - Cookbook chip row

private struct CookbookChipRow: View {
    let allCount: Int
    @ObservedObject var cookbooks: CookbooksModel
    @Binding var filter: RecipeFilter
    let onNewCookbook: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(title: "All", count: allCount, isSelected: filter == .all) {
                    filter = .all
                }
                ForEach(cookbooks.cookbooks) { cookbook in
                    FilterChip(
                        title: cookbook.name,
                        count: cookbooks.recipeCount(in: cookbook.id),
                        isSelected: filter == .cookbook(cookbook.id)
                    ) {
                        filter = .cookbook(cookbook.id)
                    }
                }
                Button(action: onNewCookbook) {
                    Text("+ New cookbook")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6)
                        .frame(height: 34)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
        }
    }
}

/// A pill filter chip: sage fill + white text when selected, hairline-bordered
/// surface otherwise. Shows "Title · N".
private struct FilterChip: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("\(title) · \(count)")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isSelected ? Color.white : Color.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background {
                    if isSelected {
                        Capsule().fill(Color.accentColor)
                    } else {
                        Capsule().fill(Color.surface)
                            .overlay(Capsule().strokeBorder(Color.hairline, lineWidth: 1))
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Cards

/// A recipe tile in the 2-column grid: square photo, serif name, ingredient count.
private struct RecipePhotoCard: View {
    let recipe: Recipe

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    RecipeImageView(imageUrl: recipe.imageUrl,
                                    fallbackSeed: recipe.recipeId,
                                    fallbackTitle: recipe.title,
                                    placeholderSymbolSize: 28)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text(recipe.title)
                .font(.editorialTitle(size: 18, relativeTo: .headline))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Text(ingredientCountText)
                .font(.caption)
                .foregroundStyle(Color.textSecondary)
        }
    }

    private var ingredientCountText: String {
        let n = recipe.ingredients.count
        return "\(n) ingredient\(n == 1 ? "" : "s")"
    }
}

/// The trailing "Add a recipe" tile: cream background, plus icon, hint text.
private struct AddRecipeTile: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        VStack(spacing: 10) {
                            Image(systemName: "plus")
                                .font(.title.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                            Text("Share a link from Instagram, TikTok or the web")
                                .font(.caption)
                                .foregroundStyle(Color.textSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 12)
                        }
                    }
                    .background(Color.creamTint)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                Text("Add a recipe")
                    .font(.editorialTitle(size: 18, relativeTo: .headline))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add a recipe")
    }
}

#Preview {
    NavigationStack {
        CookbooksGridView(
            jobs: PendingJobsModel(provider: MockRecipeProvider()),
            cookbooks: CookbooksModel()
        )
    }
}
