//
//  RecipeListView.swift
//  RecipeApp
//
//  The Recipes tab: the user's saved recipes, loaded through the injected
//  `RecipeProvider`. Tapping a row navigates to the detail screen.
//
//  Loading state is modeled explicitly so that when a real network fetch
//  replaces the mock provider, the loading and error UI already exist.
//

import SwiftUI

struct RecipeListView: View {
    let recipeProvider: RecipeProvider

    @State private var recipes: [Recipe] = []
    @State private var loadState: LoadState = .loading

    private enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    var body: some View {
        Group {
            switch loadState {
            case .loading:
                ProgressView("Loading recipes…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't load recipes", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again") { Task { await load() } }
                }
            case .loaded where recipes.isEmpty:
                ContentUnavailableView {
                    Label("No recipes yet", systemImage: "book.closed")
                } description: {
                    Text("Share a Reel or TikTok to RecipeApp and it'll show up here.")
                }
            case .loaded:
                List(recipes) { recipe in
                    NavigationLink(value: recipe) {
                        RecipeRowView(recipe: recipe)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Recipes")
        .navigationDestination(for: Recipe.self) { recipe in
            RecipeDetailView(recipe: recipe)
        }
        .task { await load() }
    }

    private func load() async {
        loadState = .loading
        do {
            recipes = try await recipeProvider.fetchRecipes()
            loadState = .loaded
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Row

struct RecipeRowView: View {
    let recipe: Recipe

    var body: some View {
        HStack(spacing: 14) {
            RecipeImageView(imageUrl: recipe.imageUrl, placeholderSymbolSize: 22)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 5) {
                Text(recipe.title)
                    .font(.headline)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    if let total = recipe.totalTimeMinutes ?? recipe.cookTimeMinutes {
                        Label(total.minutesString, systemImage: "clock")
                    }
                    Label("\(recipe.ingredients.count) items", systemImage: "list.bullet")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if recipe.isGenerated {
                    GeneratedBadge()
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        RecipeListView(recipeProvider: MockRecipeProvider())
    }
}
