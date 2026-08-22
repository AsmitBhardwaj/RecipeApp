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
    /// Called to complete the extension request and dismiss the sheet
    /// (returns to Instagram/TikTok) — the "Keep browsing" action.
    let onFinish: () -> Void
    /// Called to launch the main app via `recipeapp://` — the "Open RecipeApp"
    /// action. The host controller opens the URL and then completes the request.
    let onOpenApp: () -> Void

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

            VStack(spacing: 10) {
                // Primary: sage. Launches the main app on the Recipes tab.
                filledButton("Open RecipeApp", color: Color.accentColor, action: onOpenApp)
                // Secondary: clay. Dismisses the extension back to Instagram.
                filledButton("Keep browsing", color: Color.secondaryAccent, action: onFinish)
            }
            .padding(.top, 6)

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

    /// Full-width filled button matching the app's convention (filled accent
    /// rectangle, cream text) — used for both success-state actions.
    private func filledButton(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(color, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
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
            // the shared App Group suite (group.com.recipeapp.shared2).
            let job = try await APIRecipeProvider().submitJob(url: raw)
            PendingJobStore().upsert(
                PendingJob(jobId: job.jobId, url: raw, submittedAt: Date(), lastStatus: job.status)
            )
            // No auto-dismiss: the user now chooses "Open RecipeApp" or
            // "Keep browsing" from the success state.
            phase = .success
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
