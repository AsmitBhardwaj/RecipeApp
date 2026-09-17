//
//  PantrySuggestionsModel.swift
//  RecipeApp
//
//  Drives the "Suggestions" section on the Kitchen tab's Pantry segment. Fetches
//  POST /v1/pantry/suggestions via the SyncCoordinator (which supplies the same
//  authenticated client the rest of the account-scoped API uses) and publishes
//  the cache `matches` and generation `generated` arrays for the view.
//
//  It matches against the LOCAL pantry names (passed as `pantryOverride`) rather
//  than the server's synced copy, so suggestions reflect exactly what the user
//  sees in the list without waiting for a pantry edit to round-trip through sync.
//
//  Failures are non-fatal: an offline/unauthorized/error fetch leaves the last
//  results in place (or empty) and surfaces a quiet message — suggestions are a
//  bonus surface, never blocking the pantry itself.
//

import Foundation
import RecipeKit

@MainActor
final class PantrySuggestionsModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var matches: [PantrySuggestion] = []
    @Published private(set) var generated: [PantrySuggestion] = []

    /// The single in-flight/pending refresh. Every trigger cancels this before
    /// starting a new one, so a burst of pantry edits (or repeated sheet
    /// dismissals) collapses into exactly ONE /v1/pantry/suggestions call.
    private var refreshTask: Task<Void, Never>?

    /// True while a fetch is in flight AND we have nothing to show yet — lets the
    /// view show a spinner on first load but not flicker on a refresh.
    var isInitialLoading: Bool {
        phase == .loading && matches.isEmpty && generated.isEmpty
    }

    /// True while re-fetching but we still have prior results on screen — drives
    /// the lightweight, in-section indicator (not the full-section loader) so
    /// pantry edits stay responsive while suggestions catch up.
    var isRefreshing: Bool { phase == .loading && hasResults }

    var hasResults: Bool { !matches.isEmpty || !generated.isEmpty }

    /// Schedule a suggestions refresh, cancelling any pending one first.
    ///
    /// `debounce` collapses bursts: pass a delay (e.g. 1.5s) for pantry edits so
    /// rapid adds/removes coalesce into one call, or `.zero` for an immediate
    /// refresh (e.g. on the Pantry segment appearing). `pantryNames` is captured
    /// at call time; since every edit reschedules with the latest list, the last
    /// scheduled call carries the current pantry.
    func refresh(pantryNames: [String], via sync: SyncCoordinator, debounce: Duration = .zero) {
        refreshTask?.cancel()
        let names = pantryNames
        refreshTask = Task { [weak self] in
            if debounce > .zero {
                try? await Task.sleep(for: debounce)
                if Task.isCancelled { return }
            }
            await self?.load(pantryNames: names, via: sync)
        }
    }

    /// Fetch suggestions for the given local pantry names. Empty pantry clears the
    /// section without a network call. Prefer `refresh(...)` from views so calls
    /// stay debounced/serialized; this stays accessible for direct/testing use.
    func load(pantryNames: [String], via sync: SyncCoordinator) async {
        let names = pantryNames.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !names.isEmpty else {
            matches = []
            generated = []
            phase = .idle
            return
        }

        phase = .loading
        do {
            let response = try await sync.pantrySuggestions(pantryOverride: names)
            matches = response.matches
            generated = response.generated
            phase = .loaded
        } catch let error as RecipeProviderError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn't load suggestions right now.")
        }
    }
}
