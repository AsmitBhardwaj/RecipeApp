//
//  ShareRootView.swift
//  ShareExtension
//
//  The extension's minimal "submit and forget" UI, mirroring how AddRecipeView
//  now behaves in the main app: show "Adding to RecipeApp…", enqueue the job via
//  `APIRecipeProvider.submitJob(url:)`, persist it to the SAME `PendingJobStore`
//  (same App Group) the main app reconciles from, then auto-dismiss. It never
//  waits for extraction to finish.
//
//  Reuses RecipeKit verbatim — no networking or model code is duplicated here.
//

import SwiftUI
import RecipeKit

struct ShareRootView: View {
    /// URL string extracted from the share context (nil if none was found).
    let sharedURL: String?
    /// Called to complete the extension request and dismiss the sheet.
    let onFinish: () -> Void

    @State private var phase: Phase = .working

    private enum Phase: Equatable {
        case working
        case success
        case failure(String)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.15).ignoresSafeArea()

            VStack(spacing: 14) {
                content
            }
            .padding(24)
            .frame(maxWidth: 280)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .shadow(radius: 20, y: 8)
        }
        .task { await run() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .working:
            ProgressView()
                .controlSize(.large)
            Text("Adding to RecipeApp…")
                .font(.headline)
            Text("You can close this — we'll extract the recipe in the app.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text("Added to RecipeApp")
                .font(.headline)
            Text("Open the app to watch it turn into a recipe.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

        case .failure(let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Close") { onFinish() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
    }

    // MARK: - Submit

    private func run() async {
        // Validate + supported-link check (graceful fallback for anything the
        // activation rule let through that isn't an IG Reel / TikTok link).
        guard
            let raw = sharedURL?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty,
            let parsed = URL(string: raw),
            isSupported(parsed)
        else {
            phase = .failure("That doesn't look like an Instagram Reel or TikTok link.")
            return
        }

        do {
            // Same provider + store the main app uses. PendingJobStore defaults to
            // the shared App Group suite (group.com.recipeapp.shared).
            let job = try await APIRecipeProvider().submitJob(url: raw)
            PendingJobStore().upsert(
                PendingJob(jobId: job.jobId, url: raw, submittedAt: Date(), lastStatus: job.status)
            )
            phase = .success
            try? await Task.sleep(for: .seconds(1.2))
            onFinish()
        } catch let error as RecipeProviderError {
            phase = .failure(error.userMessage)
        } catch {
            phase = .failure("Something went wrong adding this. Please try again.")
        }
    }

    private func isSupported(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return host.contains("instagram.com")
            || host.contains("instagr.am")
            || host.contains("tiktok.com")
    }
}
