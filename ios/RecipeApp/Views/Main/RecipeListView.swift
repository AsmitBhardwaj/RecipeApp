//
//  RecipeListView.swift
//  RecipeApp
//
//  A scoped list of finished recipes. `cookbook == nil` renders "All Recipes"
//  (every finished recipe); a non-nil cookbook renders only that cookbook's
//  members. It is navigated to from `CookbooksGridView` (the Recipes-tab home).
//
//  In-flight (processing) and failed job cards are NOT shown here — they live on
//  the grid home so a share is acknowledged there immediately (CLAUDE.md §6).
//  This view is finished recipes only; membership is read live from
//  `CookbooksModel`, so it reflects edits made in the recipe detail screen.
//

import SwiftUI
import RecipeKit

struct RecipeListView: View {
    @ObservedObject var jobs: PendingJobsModel
    @ObservedObject var cookbooks: CookbooksModel
    /// nil = "All Recipes"; non-nil = a specific cookbook's members.
    var cookbook: Cookbook? = nil

    private var title: String { cookbook?.name ?? "All Recipes" }

    private var displayedRecipes: [Recipe] {
        guard let cookbook else { return jobs.recipes }
        let ids = cookbooks.recipeIds(in: cookbook.id)
        return jobs.recipes.filter { ids.contains($0.recipeId) }
    }

    var body: some View {
        ZStack {
            if displayedRecipes.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(displayedRecipes) { recipe in
                        NavigationLink(value: recipe) {
                            RecipeRowView(recipe: recipe)
                        }
                        // Recipes list uses plain solid cards (no dashed border);
                        // the torn-edge border stays the default elsewhere.
                        .tornEdgeCardRow(bordered: false)
                    }
                }
                .listStyle(.plain)
            }
        }
        .foregroundStyle(Color.textPrimary)
        .appBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(title)
                    .font(.editorialTitle(size: 22))
                    .foregroundStyle(Color.textPrimary)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if cookbook == nil {
            ContentUnavailableView {
                Label("No recipes yet", systemImage: "book.closed")
            } description: {
                Text("Tap + on the Recipes screen and paste an Instagram Reel or TikTok link to add your first recipe.")
            }
        } else {
            ContentUnavailableView {
                Label("Nothing here yet", systemImage: "books.vertical")
            } description: {
                Text("Add recipes to this cookbook from a recipe's detail screen.")
            }
        }
    }
}

// MARK: - Recipe row

struct RecipeRowView: View {
    let recipe: Recipe

    var body: some View {
        HStack(spacing: 14) {
            RecipeImageView(imageUrl: recipe.imageUrl, fallbackSeed: recipe.recipeId, fallbackTitle: recipe.title, placeholderSymbolSize: 22)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 5) {
                Text(recipe.title)
                    .font(.appRowTitle)
                    .lineLimit(2)

                if let total = recipe.totalTimeMinutes ?? recipe.cookTimeMinutes {
                    // Pill chip: subtle fill + hairline border, muted text —
                    // reuses the existing editorial tokens (textSecondary/cardEdge).
                    // Explicit tight HStack instead of Label, whose default
                    // icon-to-text spacing left a large gap inside the pill.
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                        Text(total.minutesString)
                    }
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.textSecondary.opacity(0.10), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.cardEdge, lineWidth: 1))
                }

                if recipe.isGenerated {
                    GeneratedBadge()
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Processing card

/// Skeleton/processing card for an in-flight job. Sits on the grid home where the
/// finished recipe will appear and morphs into a `RecipeRowView` when the job
/// completes.
struct ProcessingCardView: View {
    let job: PendingJob

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.borderWarm)
                .frame(width: 64, height: 64)
                .overlay { ProgressView() }

            VStack(alignment: .leading, spacing: 6) {
                Text("Extracting recipe…")
                    .font(.headline)
                    .foregroundStyle(Color.textSecondary)

                Text(displayURL)
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.borderWarm)
                    .frame(width: 120, height: 10)
            }
        }
        .padding(.vertical, 4)
    }

    private var displayURL: String {
        URL(string: job.url)?.host ?? job.url
    }
}

// MARK: - Failed card

/// Error card for a job the backend couldn't complete. Shows the reason and a
/// Dismiss action that removes it. The durable store no longer holds this job —
/// dismissing just clears the in-memory card.
struct FailedJobCardView: View {
    let job: PendingJobsModel.FailedJob
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 12)
                .fill(.red.opacity(0.12))
                .frame(width: 64, height: 64)
                .overlay {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.title3)
                }

            VStack(alignment: .leading, spacing: 5) {
                Text("Couldn't extract this one")
                    .font(.headline)

                Text(job.message)
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(3)
            }

            Spacer(minLength: 8)

            Button("Dismiss", action: onDismiss)
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
                .foregroundStyle(.tint)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        RecipeListView(
            jobs: PendingJobsModel(provider: MockRecipeProvider()),
            cookbooks: CookbooksModel()
        )
    }
}
