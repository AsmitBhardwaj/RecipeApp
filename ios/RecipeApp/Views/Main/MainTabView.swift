//
//  MainTabView.swift
//  RecipeApp
//
//  The tab shell: Recipes (with Cookbooks folded in), Meal Plan, and Grocery
//  List. Account is reached from a toolbar icon on the Recipes screen, not a tab.
//  Grocery List is a "coming soon" shell for now. DiscoverView still exists but
//  is intentionally not in the tab bar yet — re-add a tab for it once built out.
//
//  Owns the app-wide `PendingJobsModel` so in-flight jobs and finished recipes
//  live above the tabs (surviving tab switches and the Add sheet), and drives
//  foreground reconciliation: on launch and every time the app becomes active it
//  re-polls the App Group's pending jobs to catch anything that resolved while
//  backgrounded or killed (CLAUDE.md §6, layer 3). It also supplies the recipe
//  list to the Meal Plan tab's assign-picker.
//

import SwiftUI
import RecipeKit

struct MainTabView: View {
    @StateObject private var jobs: PendingJobsModel
    @StateObject private var cookbooks: CookbooksModel
    @StateObject private var sync: SyncCoordinator
    private let userScope: String
    /// Stage 4: non-nil once, right after the "claim your data" migration runs on
    /// first sign-in. Drives the confirmation toast, then is cleared on dismiss.
    @State private var claimSummary: ClaimSummary?
    @Environment(\.scenePhase) private var scenePhase
    /// Which tab is showing. Bound so `onOpenURL` (launch via `recipeapp://`
    /// from the Share Extension) can force the Recipes tab, where the new
    /// processing card lives.
    @State private var selectedTab: Tab = .recipes

    private enum Tab: Hashable {
        case recipes, mealPlan, grocery
    }

    init(recipeProvider: RecipeProvider, auth: AuthModel) {
        let userId = auth.currentUser?.id ?? "unknown"
        // Stage 4 "claim your data": migrate any pre-account (legacy) local data
        // into this account BEFORE the view models below read their scoped stores,
        // so claimed recipes/lists show immediately (not only after the next sync).
        // Idempotent + device-global: a cheap no-op after the first sign-in.
        let claim = LegacyDataClaimer(userId: userId).claimIfNeeded()
        _claimSummary = State(initialValue: claim)
        let coordinator = SyncCoordinator(userId: userId, tokenProvider: { try await auth.validAccessToken() })
        self.userScope = userId
        _sync = StateObject(wrappedValue: coordinator)
        _jobs = StateObject(wrappedValue: PendingJobsModel(provider: recipeProvider, userScope: userId, sync: coordinator))
        _cookbooks = StateObject(wrappedValue: CookbooksModel(userScope: userId, sync: coordinator))
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                CookbooksGridView(jobs: jobs, cookbooks: cookbooks, userScope: userScope)
            }
            .tabItem {
                Label("Recipes", systemImage: "book.closed.fill")
            }
            .tag(Tab.recipes)

            NavigationStack {
                MealPlanView(jobs: jobs, cookbooks: cookbooks, userScope: userScope, sync: sync)
            }
            .tabItem {
                Label("Meal Plan", systemImage: "calendar")
            }
            .tag(Tab.mealPlan)

            NavigationStack {
                GroceryListView(jobs: jobs, userScope: userScope, sync: sync)
            }
            .tabItem {
                Label("Grocery List", systemImage: "cart")
            }
            .tag(Tab.grocery)
        }
        .task {
            jobs.reconcile()
            sync.triggerSync()  // pull remote changes + flush outbox on launch/sign-in
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                jobs.reconcile()
                sync.triggerSync()
            }
        }
        // Launched via `recipeapp://` (Share Extension "Open RecipeApp"): bring
        // the user to the Recipes tab so the just-submitted job's processing card
        // is visible. The `.active` reconcile above then refreshes it.
        .onOpenURL { url in
            if url.scheme == "recipeapp" {
                selectedTab = .recipes
                jobs.reconcile()
            }
        }
        // One-time failure modal, app-wide so it surfaces over whatever tab the
        // user is on when a live poll or foreground reconcile detects a failure.
        // Custom overlay (not a native .alert) so the OK button can be a filled
        // sage rectangle — native alerts only tint button text. The failed card
        // in the Recipes list remains for detailed review.
        .overlay {
            if let alert = jobs.failureAlert {
                FailureAlertView(
                    title: "Couldn't add recipe 😔",
                    message: alert.message,
                    onDismiss: { jobs.clearFailureAlert() }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: jobs.failureAlert)
        // Stage 4 "claim your data" confirmation — top, non-blocking, self-dismissing.
        .overlay(alignment: .top) {
            if let summary = claimSummary {
                ClaimToastView(summary: summary)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        withAnimation { claimSummary = nil }
                    }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: claimSummary)
    }
}

#Preview {
    MainTabView(recipeProvider: MockRecipeProvider(), auth: AuthModel())
}
