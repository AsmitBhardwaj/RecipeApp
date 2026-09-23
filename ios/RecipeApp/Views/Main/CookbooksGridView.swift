//
//  CookbooksGridView.swift
//  RecipeApp
//
//  Recipes-tab home. Cookbooks and the full recipe library are two in-place
//  sections, with one shared add affordance and the existing creation flows.
//

import SwiftUI
import RecipeKit

struct CookbooksGridView: View {
    @ObservedObject var jobs: PendingJobsModel
    @ObservedObject var cookbooks: CookbooksModel
    var userScope: String? = nil

    @EnvironmentObject private var subscriptions: SubscriptionService

    @State private var section: RecipesSection = .cookbooks
    @State private var searchText = ""
    @State private var sortOrder: RecipeSortOrder = .newest
    @State private var cookbookFilterID: String?
    @State private var showingAddMenu = false
    @State private var showingAdd = false
    @State private var showingAccount = false
    @State private var showingNewCookbook = false
    @State private var newCookbookName = ""
    @State private var pasteTarget: PendingJobsModel.FailedJob?
    /// Platter Pro paywall, shown after an add/paste sheet dismisses because the
    /// free import limit was hit. `pendingPaywall` bridges the child's callback to
    /// the sheet's `onDismiss` so we never present two sheets at once.
    @State private var showPaywall = false
    @State private var pendingPaywall = false

    private let columns = [
        GridItem(.flexible(), spacing: Theme.Spacing.md),
        GridItem(.flexible(), spacing: Theme.Spacing.md)
    ]

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                header
                sectionPicker
                content
            }

            floatingAddButton
        }
        .foregroundStyle(Color.textPrimary)
        .appBackground()
        .toolbar(.hidden, for: .navigationBar)
        .confirmationDialog("Add to Recipes", isPresented: $showingAddMenu, titleVisibility: .hidden) {
            if section == .cookbooks {
                Button("New Cookbook") { showingNewCookbook = true }
                Button("Add Recipe") { showingAdd = true }
            } else {
                Button("Add Recipe") { showingAdd = true }
                Button("New Cookbook") { showingNewCookbook = true }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingAdd, onDismiss: presentPaywallIfPending) {
            AddRecipeView(jobs: jobs, onLimitReached: { pendingPaywall = true })
        }
        .sheet(item: $pasteTarget, onDismiss: presentPaywallIfPending) { failedJob in
            PasteRecipeTextView(jobs: jobs, failedJob: failedJob, onLimitReached: { pendingPaywall = true })
        }
        .sheet(isPresented: $showPaywall) {
            PlatterProPaywallView()
                .environmentObject(subscriptions)
        }
        .sheet(isPresented: $showingAccount) {
            NavigationStack {
                AccountView()
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
        .navigationDestination(for: Recipe.self) { recipe in
            RecipeDetailView(recipe: recipe, cookbooks: cookbooks, userScope: userScope)
        }
        .task { await jobs.load() }
        .onChange(of: section) { _, _ in
            searchText = ""
        }
    }

    private var header: some View {
        ScreenHeader("Recipes.") {
            CircleHeaderButton(
                systemImage: "person.crop.circle",
                accessibilityLabel: "Account"
            ) {
                showingAccount = true
            }
        }
    }

    private var sectionPicker: some View {
        SegmentedPill(
            segments: [
                .init(title: "Cookbooks", value: RecipesSection.cookbooks),
                .init(title: "All Recipes", value: RecipesSection.allRecipes)
            ],
            selection: $section
        )
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.lg)
        .accessibilityLabel("Recipe library section")
    }

    @ViewBuilder
    private var content: some View {
        switch jobs.loadState {
        case .loading:
            ProgressView(section == .cookbooks ? "Loading cookbooks…" : "Loading recipes…")
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
            loadedContent
        }
    }

    private var loadedContent: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Spacing.lg) {
                searchControls
                jobStatusCards

                if section == .cookbooks {
                    cookbooksContent
                } else {
                    recipesContent
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.bottom, Theme.Spacing.tabBarClearance + 48)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var searchControls: some View {
        HStack(spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.textSecondary)

                TextField(
                    section == .cookbooks ? "Search cookbooks" : "Search recipes",
                    text: $searchText
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .frame(minHeight: 44)
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.hairline, lineWidth: 1)
            }

            if section == .allRecipes {
                recipeOptionsMenu
            }
        }
    }

    private var recipeOptionsMenu: some View {
        Menu {
            Section("Sort") {
                Picker("Sort", selection: $sortOrder) {
                    Label("Newest", systemImage: "clock")
                        .tag(RecipeSortOrder.newest)
                    Label("Title", systemImage: "textformat.abc")
                        .tag(RecipeSortOrder.title)
                }
            }

            Section("Filter by Cookbook") {
                Button {
                    cookbookFilterID = nil
                } label: {
                    if cookbookFilterID == nil {
                        Label("All Cookbooks", systemImage: "checkmark")
                    } else {
                        Text("All Cookbooks")
                    }
                }

                ForEach(cookbooks.cookbooks) { cookbook in
                    Button {
                        cookbookFilterID = cookbook.id
                    } label: {
                        if cookbookFilterID == cookbook.id {
                            Label(cookbook.name, systemImage: "checkmark")
                        } else {
                            Text(cookbook.name)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: cookbookFilterID == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(cookbookFilterID == nil ? Color.textPrimary : Color.accentColor)
                .frame(width: 44, height: 44)
                .background(Color.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.hairline, lineWidth: 1)
                }
        }
        .accessibilityLabel("Sort and filter recipes")
    }

    @ViewBuilder
    private var jobStatusCards: some View {
        ForEach(jobs.failed) { failedJob in
            FailedJobCardView(
                job: failedJob,
                onDismiss: { jobs.dismissFailed(jobId: failedJob.jobId) },
                onPasteText: failedJob.canPasteText ? { pasteTarget = failedJob } : nil
            )
            .card()
        }

        ForEach(jobs.pending) { pendingJob in
            ProcessingCardView(job: pendingJob)
                .card()
        }
    }

    private var filteredCookbooks: [Cookbook] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return cookbooks.cookbooks }
        return cookbooks.cookbooks.filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    @ViewBuilder
    private var cookbooksContent: some View {
        if filteredCookbooks.isEmpty {
            ContentUnavailableView {
                Label(
                    searchText.isEmpty ? "No cookbooks yet" : "No cookbooks found",
                    systemImage: "books.vertical"
                )
            } description: {
                Text(searchText.isEmpty
                     ? "Tap + to create your first cookbook."
                     : "Try a different search.")
            }
            .padding(.top, Theme.Spacing.xxl)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Spacing.xl) {
                ForEach(filteredCookbooks) { cookbook in
                    NavigationLink {
                        RecipeListView(jobs: jobs, cookbooks: cookbooks, cookbook: cookbook)
                    } label: {
                        CookbookCard(
                            cookbook: cookbook,
                            recipes: recipes(in: cookbook),
                            recipeCount: cookbooks.recipeCount(in: cookbook.id)
                        )
                    }
                    .buttonStyle(.plain)
                    // LazyVGrid → context-menu delete (see the recipes grid note).
                    // Deletes the cookbook only; its recipes stay in the library.
                    .contextMenu {
                        Button(role: .destructive) { cookbooks.delete(cookbook) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    /// Delete a recipe from the library (shared body + `.library` tombstone) and
    /// strip its cookbook memberships so counts stay correct — same pairing as
    /// RecipeListView's swipe delete; both halves propagate via sync.
    private func deleteRecipe(_ recipe: Recipe) {
        jobs.deleteRecipe(recipe)
        cookbooks.removeRecipeFromAllCookbooks(recipe.recipeId)
    }

    private func recipes(in cookbook: Cookbook) -> [Recipe] {
        let ids = cookbooks.recipeIds(in: cookbook.id)
        return jobs.recipes.filter { ids.contains($0.recipeId) }
    }

    private var displayedRecipes: [Recipe] {
        let scoped: [Recipe]
        if let cookbookFilterID {
            let ids = cookbooks.recipeIds(in: cookbookFilterID)
            scoped = jobs.recipes.filter { ids.contains($0.recipeId) }
        } else {
            scoped = jobs.recipes
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let searched = query.isEmpty
            ? scoped
            : scoped.filter { $0.title.localizedCaseInsensitiveContains(query) }

        switch sortOrder {
        case .newest:
            return searched
        case .title:
            return searched.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }
    }

    @ViewBuilder
    private var recipesContent: some View {
        if displayedRecipes.isEmpty {
            if jobs.pending.isEmpty && jobs.failed.isEmpty {
                ContentUnavailableView {
                    Label(
                        jobs.recipes.isEmpty ? "No recipes yet" : "No recipes found",
                        systemImage: "book.closed"
                    )
                } description: {
                    Text(jobs.recipes.isEmpty
                         ? "Tap + to add your first recipe."
                         : "Try changing your search or filter.")
                }
                .padding(.top, Theme.Spacing.xxl)
            }
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Spacing.xl) {
                ForEach(displayedRecipes) { recipe in
                    NavigationLink(value: recipe) {
                        RecipePhotoCard(recipe: recipe)
                    }
                    .buttonStyle(.plain)
                    // This section is a LazyVGrid, so native .swipeActions (List-only)
                    // don't apply — a long-press context menu is the grid-native
                    // delete affordance, matching Pantry/Meal Plan's context menus.
                    .contextMenu {
                        Button(role: .destructive) { deleteRecipe(recipe) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private var floatingAddButton: some View {
        Button {
            showingAddMenu = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 56, height: 56)
                .background(Color.accentColor)
                .clipShape(Circle())
                .shadow(color: Color.black.opacity(0.14), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .padding(.trailing, Theme.Spacing.xl)
        // This ZStack fills the tab's viewport and already respects the native
        // tab bar safe area. A small inset here keeps the button just above the
        // bar instead of lifting it into the cookbook grid.
        .padding(.bottom, 18)
        .accessibilityLabel(section == .cookbooks ? "Add cookbook or recipe" : "Add recipe or cookbook")
    }

    /// Present the paywall once the add/paste sheet that hit the import limit has
    /// finished dismissing (SwiftUI can't cleanly present a second sheet while the
    /// first is still on screen).
    private func presentPaywallIfPending() {
        if pendingPaywall {
            pendingPaywall = false
            showPaywall = true
        }
    }
}

private enum RecipesSection: Hashable {
    case cookbooks
    case allRecipes
}

private enum RecipeSortOrder: Hashable {
    case newest
    case title
}

private struct CookbookCard: View {
    let cookbook: Cookbook
    let recipes: [Recipe]
    let recipeCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            CookbookCover(recipes: Array(recipes.prefix(4)))

            Text(cookbook.name)
                .font(.editorialTitle(size: 18, relativeTo: .headline))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Text("\(recipeCount) Recipe\(recipeCount == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(Color.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(cookbook.name), \(recipeCount) recipe\(recipeCount == 1 ? "" : "s")")
        .accessibilityHint("Opens cookbook")
    }
}

private struct CookbookCover: View {
    let recipes: [Recipe]

    var body: some View {
        Color.clear
            .aspectRatio(1.05, contentMode: .fit)
            .overlay {
                Group {
                    switch recipes.count {
                    case 0:
                        emptyCover
                    case 1:
                        coverImage(recipes[0])
                    case 2:
                        HStack(spacing: 2) {
                            coverImage(recipes[0])
                            coverImage(recipes[1])
                        }
                    default:
                        VStack(spacing: 2) {
                            HStack(spacing: 2) {
                                coverImage(recipes[0])
                                coverImage(recipes[1])
                            }
                            HStack(spacing: 2) {
                                coverImage(recipes[2])
                                if recipes.count > 3 {
                                    coverImage(recipes[3])
                                } else {
                                    Color.creamTint
                                }
                            }
                        }
                    }
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityHidden(true)
    }

    private var emptyCover: some View {
        Color.creamTint
            .overlay {
                Image(systemName: "books.vertical")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
    }

    private func coverImage(_ recipe: Recipe) -> some View {
        RecipeImageView(
            imageUrl: recipe.imageUrl,
            fallbackSeed: recipe.recipeId,
            fallbackTitle: recipe.title,
            placeholderSymbolSize: 24
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

/// The existing recipe tile: square photo, serif name, ingredient count.
private struct RecipePhotoCard: View {
    let recipe: Recipe

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    RecipeImageView(
                        imageUrl: recipe.imageUrl,
                        fallbackSeed: recipe.recipeId,
                        fallbackTitle: recipe.title,
                        placeholderSymbolSize: 28
                    )
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
        let count = recipe.ingredients.count
        return "\(count) ingredient\(count == 1 ? "" : "s")"
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
