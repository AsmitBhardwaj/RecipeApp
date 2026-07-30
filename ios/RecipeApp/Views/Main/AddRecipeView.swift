//
//  AddRecipeView.swift
//  RecipeApp
//
//  "Add a recipe from a link" sheet: paste a URL, enqueue a job, and close.
//  This is submit-and-close (CLAUDE.md §6): it hands the URL to
//  `PendingJobsModel.submit`, which POSTs to the backend, persists the job in
//  the App Group, and starts polling. As soon as the job is enqueued the sheet
//  dismisses — the processing card in the Recipes list takes over from here and
//  morphs into the finished recipe when the job resolves.
//
//  Only the immediate enqueue failure (invalid URL / offline / HTTP error)
//  surfaces here; anything that happens after the job exists is shown on the
//  card, not in this modal.
//

import SwiftUI
import RecipeKit

struct AddRecipeView: View {
    @ObservedObject var jobs: PendingJobsModel

    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var phase: Phase = .idle

    private enum Phase: Equatable {
        case idle
        case submitting
        case failed(String)
    }

    private var isSubmitting: Bool { phase == .submitting }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Paste a link — Instagram, TikTok, or a recipe website", text: $urlText, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .disabled(isSubmitting)
                } footer: {
                    Text("We'll pull the recipe from the post or page. You can close this while it works — it'll appear in your list.")
                        .foregroundStyle(Color.textSecondary)
                }

                if case .failed(let message) = phase {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }

                Section {
                    Button(action: submit) {
                        if isSubmitting {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Submitting…")
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            Text("Get recipe")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(isSubmitting || urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .foregroundStyle(.tint)
                }
            }
            .foregroundStyle(Color.textPrimary)
            .appBackground()
            .navigationTitle("Add recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting)
                }
            }
            .interactiveDismissDisabled(isSubmitting)
        }
    }

    private func submit() {
        phase = .submitting
        Task {
            do {
                try await jobs.submit(url: urlText)
                // Job enqueued and now tracked as a processing card — close.
                dismiss()
            } catch let error as RecipeProviderError {
                phase = .failed(error.userMessage)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}

#Preview {
    AddRecipeView(jobs: PendingJobsModel(provider: MockRecipeProvider()))
}
