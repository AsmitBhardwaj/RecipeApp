//
//  PasteRecipeTextView.swift
//  RecipeApp
//
//  The manual "paste the recipe text" fallback — the remedy for a failed job
//  where we couldn't obtain or read the source (e.g. a publisher's bot
//  protection returned `site_blocked`, or an Instagram caption couldn't be
//  read). The user copies the recipe text off the page/post and pastes it here;
//  we send it to POST /v1/jobs/{id}/paste, which re-runs extraction on the
//  pasted text IN PLACE and returns the finished recipe.
//
//  Mirrors AddRecipeView's shape (Form + submit button + inline failure), but
//  the caller waits on the result here (rather than closing immediately), since
//  the whole point is to turn the failed card into a real recipe.
//

import SwiftUI
import RecipeKit

struct PasteRecipeTextView: View {
    @ObservedObject var jobs: PendingJobsModel
    let failedJob: PendingJobsModel.FailedJob

    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var phase: Phase = .idle

    private enum Phase: Equatable {
        case idle
        case submitting
        case failed(String)
    }

    private var isSubmitting: Bool { phase == .submitting }
    /// The backend requires at least a little text to work with (see
    /// paste_job_text). Guard the same threshold client-side.
    private var canSubmit: Bool {
        !isSubmitting && text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 10
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ZStack(alignment: .topLeading) {
                        // TextEditor has no native placeholder — overlay one.
                        if text.isEmpty {
                            Text("Paste the ingredients and steps here…")
                                .foregroundStyle(Color.textSecondary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $text)
                            .frame(minHeight: 220)
                            .autocorrectionDisabled()
                            .disabled(isSubmitting)
                    }
                } header: {
                    Text("Recipe text")
                } footer: {
                    Text("This site blocks automatic import, so copy the recipe from the page and paste it above. We'll pull out the ingredients and steps for you.")
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
                                Text("Reading the recipe…")
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            Text("Get recipe")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(!canSubmit)
                    .foregroundStyle(.tint)
                }
            }
            .foregroundStyle(Color.textPrimary)
            .appBackground()
            .navigationTitle("Paste recipe")
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
                try await jobs.submitPastedText(jobId: failedJob.jobId, text: text)
                // Recipe is now in the list and the failed card is cleared — done.
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
    PasteRecipeTextView(
        jobs: PendingJobsModel(provider: MockRecipeProvider()),
        failedJob: .init(
            jobId: "job_1",
            url: "https://www.allrecipes.com/recipe/158968/",
            message: "This site blocks automatic import. Paste the recipe text and we'll do the rest.",
            errorCode: "site_blocked"
        )
    )
}
