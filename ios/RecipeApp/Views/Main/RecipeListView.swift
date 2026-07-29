//
//  RecipeListView.swift
//  RecipeApp
//
//  The Recipes tab. Renders three kinds of rows from a single observable source
//  (`PendingJobsModel`): failed-job cards needing attention, processing cards for
//  in-flight jobs, and finished recipes. A processing card morphs into a recipe
//  row the moment its job resolves (CLAUDE.md §3) — both are just different
//  states of the same model, so no manual reload is needed.
//
//  Pending state is sourced from the App Group store via the model, NOT from
//  local view state, so it survives this view (and the app) coming and going.
//

import SwiftUI
import RecipeKit

struct RecipeListView: View {
    @ObservedObject var jobs: PendingJobsModel

    @State private var showingAdd = false
    @State private var showingAccount = false

    var body: some View {
        // A stable container (not a transparent `Group`) so the `.task` below is
        // hosted on an identity that persists across branch changes. Attaching it
        // to a `Group` whose `switch` swaps between ProgressView / List / empty
        // views made the branch's identity changes restart the task, re-running
        // the one-time load and wiping the list.
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
            case .loaded where jobs.recipes.isEmpty && jobs.pending.isEmpty && jobs.failed.isEmpty:
                ContentUnavailableView {
                    Label("No recipes yet", systemImage: "book.closed")
                } description: {
                    Text("Tap + and paste an Instagram Reel or TikTok link to add your first recipe.")
                }
            case .loaded:
                List {
                    // Needs-attention first, then in-flight, then finished.
                    ForEach(jobs.failed) { failedJob in
                        FailedJobCardView(job: failedJob) {
                            jobs.dismissFailed(jobId: failedJob.jobId)
                        }
                        .tornEdgeCardRow()
                    }
                    ForEach(jobs.pending) { pendingJob in
                        ProcessingCardView(job: pendingJob)
                            .tornEdgeCardRow()
                    }
                    ForEach(jobs.recipes) { recipe in
                        NavigationLink(value: recipe) {
                            RecipeRowView(recipe: recipe)
                        }
                        .tornEdgeCardRow()
                    }
                }
                .listStyle(.plain)
            }
        }
        .foregroundStyle(Color.textPrimary)
        .appBackground()
        // Add is a floating button at the bottom-right (above the tab bar),
        // shown once the list has loaded. Account lives in the top-right.
        .overlay(alignment: .bottomTrailing) {
            if jobs.loadState == .loaded {
                addButton
            }
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
                Button {
                    showingAccount = true
                } label: {
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
        .navigationDestination(for: Recipe.self) { recipe in
            RecipeDetailView(recipe: recipe)
        }
        .task { await jobs.load() }
    }

    /// Floating "+" action button (bottom-right), replacing the old toolbar item.
    private var addButton: some View {
        Button {
            showingAdd = true
        } label: {
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

// MARK: - Recipe row

struct RecipeRowView: View {
    let recipe: Recipe

    var body: some View {
        HStack(spacing: 14) {
            RecipeImageView(imageUrl: recipe.imageUrl, placeholderSymbolSize: 22)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 5) {
                Text(recipe.title)
                    .font(.editorialTitle(size: 19, relativeTo: .headline))
                    .lineLimit(2)

                HStack(spacing: 8) {
                    if let total = recipe.totalTimeMinutes ?? recipe.cookTimeMinutes {
                        Label(total.minutesString, systemImage: "clock")
                    }
                    Label("\(recipe.ingredients.count) items", systemImage: "list.bullet")
                }
                .font(.caption)
                .foregroundStyle(Color.textSecondary)

                if recipe.isGenerated {
                    GeneratedBadge()
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Processing card

/// Skeleton/processing card for an in-flight job. Sits in the list where the
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
        RecipeListView(jobs: PendingJobsModel(provider: MockRecipeProvider()))
    }
}
