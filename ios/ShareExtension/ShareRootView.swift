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

/// Carries the shared URL from the host controller into the SwiftUI view without
/// gating the view's *presentation* on the (potentially slow) `loadItem` call.
///
/// The controller presents `ShareRootView` immediately in `viewDidLoad` — so the
/// "extracting" message paints at once — and resolves this box asynchronously when
/// the share item finishes loading. `ShareRootView.run()` awaits `urlValue()`, so
/// only the *submit* waits on the URL, never the first paint.
///
/// All access is on the main thread (the controller resolves from a
/// main-queue-dispatched completion; the view awaits from its `.task`), so the
/// tiny continuation buffer needs no extra locking.
///
/// Not `ObservableObject`: the view never re-renders on this — it only `await`s
/// `urlValue()` once from `run()`, so a plain reference type is enough.
final class SharedURLBox {
    enum State: Equatable {
        case loading
        case resolved(String?)   // nil = no usable URL found in the share
    }

    private var state: State = .loading
    private var waiters: [CheckedContinuation<String?, Never>] = []

    /// Called once by the controller when `loadItem` completes. Idempotent: a
    /// second call after resolution is ignored.
    func resolve(_ url: String?) {
        guard case .loading = state else { return }
        state = .resolved(url)
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: url) }
    }

    /// Awaits the resolved URL, returning immediately if it already arrived.
    func urlValue() async -> String? {
        if case .resolved(let url) = state { return url }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

struct ShareRootView: View {
    /// Resolves to the shared URL asynchronously; presenting the view does not
    /// wait on it (see `SharedURLBox`).
    let urlBox: SharedURLBox
    /// Called to complete the extension request and dismiss the sheet
    /// (returns to Instagram/TikTok) — the "Keep browsing" action.
    let onFinish: () -> Void

    @State private var phase: Phase = .working

    // Named lookups (NOT Color.accentColor): the extension has no designated
    // global accent, so Color.accentColor resolves to system blue. These read
    // the copied colorsets in ShareExtension/Assets.xcassets directly.
    private let sage = Color("AccentColor")
    private let cream = Color("AppBackground")

    private enum Phase: Equatable {
        case working
        case success
        case failure(String)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.25).ignoresSafeArea()

            // Bottom-anchored sheet (like a native action sheet), cream surface
            // with rounded top corners, flush to the screen's bottom edge.
            VStack(spacing: 14) {
                content
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 22)
            .padding(.top, 24)
            .padding(.bottom, 20)
            .background(
                UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22, style: .continuous)
                    .fill(cream)
                    .ignoresSafeArea(edges: .bottom)
                    .shadow(color: .black.opacity(0.18), radius: 18, y: -3)
            )
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
            Text("Saved — find it in the app")
                .font(.headline)
            Text("Open RecipeApp whenever you like to watch it turn into a recipe.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Single action: dismiss and return to Instagram/TikTok. The job is
            // already queued in the shared PendingJobStore, so there's nothing to
            // wait on here.
            filledButton("Keep browsing", action: onFinish)
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

    /// Solid sage button, cream/white text — the success screen's single action.
    private func filledButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(sage, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Submit

    private func run() async {
        // Wait for the share item to finish loading. The view is already on
        // screen showing the "extracting" message — only the submit below waits.
        let sharedURL = await urlBox.urlValue()

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
            // No auto-dismiss: the user taps "Keep browsing" to return to
            // Instagram/TikTok from the success state.
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
