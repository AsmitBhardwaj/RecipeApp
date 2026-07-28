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
                    }
                    ForEach(jobs.pending) { pendingJob in
                        ProcessingCardView(job: pendingJob)
                    }
                    ForEach(jobs.recipes) { recipe in
                        NavigationLink(value: recipe) {
                            RecipeRowView(recipe: recipe)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Recipes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAdd = true
                } label: {
                    Label("Add recipe", systemImage: "plus")
                }
                .disabled(jobs.loadState == .loading)
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddRecipeView(jobs: jobs)
        }
        .navigationDestination(for: Recipe.self) { recipe in
            RecipeDetailView(recipe: recipe)
        }
        .task { await jobs.load() }
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

// MARK: - Processing card

/// Skeleton/processing card for an in-flight job. Sits in the list where the
/// finished recipe will appear and morphs into a `RecipeRowView` when the job
/// completes.
struct ProcessingCardView: View {
    let job: PendingJob

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 12)
                .fill(.quaternary)
                .frame(width: 64, height: 64)
                .overlay { ProgressView() }

            VStack(alignment: .leading, spacing: 6) {
                Text("Extracting recipe…")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Text(displayURL)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
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
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Spacer(minLength: 8)

            Button("Dismiss", action: onDismiss)
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        RecipeListView(jobs: PendingJobsModel(provider: MockRecipeProvider()))
    }
}
