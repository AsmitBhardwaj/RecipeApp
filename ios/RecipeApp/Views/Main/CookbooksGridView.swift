//
//  CookbooksGridView.swift
//  RecipeApp
//
//  The Recipes-tab home: a grid of cookbook cards. "All Recipes" is a permanent,
//  non-deletable card showing every recipe regardless of assignment; user
//  cookbooks follow; a "New Cookbook" card creates one. Tapping a card pushes a
//  scoped `RecipeListView`.
//
//  This view also owns the tab-level concerns that used to live on the flat list:
//  loading/failed states, the add-recipe (+) and Account affordances, and — so a
//  share is acknowledged the moment the user lands here (CLAUDE.md §6) — the
//  in-flight (processing) and failed job cards, shown above the grid.
//

import SwiftUI
import RecipeKit

/// What a cookbook card navigates to. `.all` is the synthetic "All Recipes".
enum RecipeScope: Hashable {
    case all
    case cookbook(Cookbook)
}

struct CookbooksGridView: View {
    @ObservedObject var jobs: PendingJobsModel
    @ObservedObject var cookbooks: CookbooksModel

    @State private var showingAdd = false
    @State private var showingAccount = false
    @State private var showingNewCookbook = false
    @State private var newCookbookName = ""

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
        .overlay(alignment: .bottomTrailing) {
            if jobs.loadState == .loaded { addButton }
        }
        .navigationTitle("Recipes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Recipes")
                    .font(.editorialTitle(size: 22))
                    .foregroundStyle(Color.textPrimary)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAccount = true } label: {
                    Image(systemName: "person.crop.circle")
                }
                .accessibilityLabel("Account")
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddRecipeView(jobs: jobs)
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
        // Scoped list push (All Recipes / a cookbook).
        .navigationDestination(for: RecipeScope.self) { scope in
            switch scope {
            case .all:
                RecipeListView(jobs: jobs, cookbooks: cookbooks, cookbook: nil)
            case .cookbook(let cookbook):
                RecipeListView(jobs: jobs, cookbooks: cookbooks, cookbook: cookbook)
            }
        }
        // Recipe detail push (from any scoped list).
        .navigationDestination(for: Recipe.self) { recipe in
            RecipeDetailView(recipe: recipe, cookbooks: cookbooks)
        }
        .task { await jobs.load() }
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                // In-flight / failed job cards first, so a just-submitted share is
                // acknowledged here on the tab home.
                ForEach(jobs.failed) { failedJob in
                    FailedJobCardView(job: failedJob) {
                        jobs.dismissFailed(jobId: failedJob.jobId)
                    }
                    .tornEdgeCard()
                }
                ForEach(jobs.pending) { pendingJob in
                    ProcessingCardView(job: pendingJob)
                        .tornEdgeCard()
                }

                LazyVGrid(columns: columns, spacing: 14) {
                    // Permanent "All Recipes" first.
                    NavigationLink(value: RecipeScope.all) {
                        CookbookCard(title: "All Recipes",
                                     count: jobs.recipes.count,
                                     systemImage: "square.stack",
                                     isAllRecipes: true)
                    }
                    .buttonStyle(.plain)

                    ForEach(cookbooks.cookbooks) { cookbook in
                        NavigationLink(value: RecipeScope.cookbook(cookbook)) {
                            CookbookCard(title: cookbook.name,
                                         count: cookbooks.recipeCount(in: cookbook.id),
                                         systemImage: "book.closed",
                                         isAllRecipes: false)
                        }
                        .buttonStyle(.plain)
                    }

                    NewCookbookCard { showingNewCookbook = true }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 96)  // clear the floating add button
        }
    }

    private var addButton: some View {
        Button { showingAdd = true } label: {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(.tint, in: Circle())
                .shadow(radius: 4, y: 2)
        }
        .padding(.trailing, 20)
        .padding(.bottom, 20)
        .accessibilityLabel("Add recipe")
    }
}

// MARK: - Cards

/// A cookbook tile in the editorial torn-edge style with a serif title.
private struct CookbookCard: View {
    let title: String
    let count: Int
    let systemImage: String
    let isAllRecipes: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(isAllRecipes ? Color.secondaryAccent : Color.accentColor)
            Spacer(minLength: 0)
            Text(title)
                .font(.editorialTitle(size: 20, relativeTo: .title3))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(count == 1 ? "1 recipe" : "\(count) recipes")
                .font(.caption)
                .foregroundStyle(Color.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
        .tornEdgeCard(bordered: false)
    }
}

/// The "+ New Cookbook" tile — a solid card matching the others (no dashed border).
private struct NewCookbookCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.tint)
                Text("New Cookbook")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 132)
            .background(Color.appBackground, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
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
