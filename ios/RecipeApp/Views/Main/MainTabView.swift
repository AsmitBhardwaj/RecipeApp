//
//  MainTabView.swift
//  RecipeApp
//
//  The tab shell: Recipes (with Cookbooks folded in), Meal Plan, and Kitchen
//  (which now folds Grocery List and Pantry behind one segmented picker — see
//  KitchenTabView). Account is reached from a toolbar icon on the Recipes screen,
//  not a tab. DiscoverView still exists but is intentionally not in the tab bar
//  yet — re-add a tab for it once built out.
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
    private let auth: AuthModel
    /// Stage 4: non-nil once, right after the "claim your data" migration runs on
    /// first sign-in. Drives the confirmation toast, then is cleared on dismiss.
    @State private var claimSummary: ClaimSummary?
    @Environment(\.scenePhase) private var scenePhase
    /// The app-wide entitlement service (injected at the app root). Drives the
    /// app-open paywall decision (free vs Pro, server-resolved, in-progress states).
    @EnvironmentObject private var subscriptions: SubscriptionService
    /// Periodic app-open paywall presentation.
    @State private var showingAppOpenPaywall = false
    /// True for the current foreground activation if it was started by a
    /// `recipeapp://` share/import deep link — suppresses the app-open paywall.
    @State private var launchedFromShareThisActivation = false
    private let appOpenPaywallStore = PaywallPresentationStore()
    /// Which tab is showing. Bound so `onOpenURL` (launch via `recipeapp://`
    /// from the Share Extension) can force the Recipes tab, where the new
    /// processing card lives.
    @State private var selectedTab: Tab = .recipes

    private enum Tab: Hashable {
        case recipes, mealPlan, kitchen
    }

    init(
        recipeProvider: RecipeProvider,
        auth: AuthModel,
        subscriptions: SubscriptionService
    ) {
        let userId = auth.currentUser?.id ?? "unknown"
        self.auth = auth
        // Stage 4 "claim your data": migrate any pre-account (legacy) local data
        // into this account BEFORE the view models below read their scoped stores,
        // so claimed recipes/lists show immediately (not only after the next sync).
        // Idempotent + device-global: a cheap no-op after the first sign-in.
        let claim = LegacyDataClaimer(userId: userId).claimIfNeeded()
        _claimSummary = State(initialValue: claim)
        let coordinator = SyncCoordinator(
            userId: userId,
            tokenProvider: { try await auth.validAccessToken() }
        )
        self.userScope = userId
        _sync = StateObject(wrappedValue: coordinator)
        _jobs = StateObject(wrappedValue: PendingJobsModel(provider: recipeProvider, userScope: userId, sync: coordinator))
        _cookbooks = StateObject(wrappedValue: CookbooksModel(userScope: userId, sync: coordinator))
    }

    var body: some View {
        TabView(selection: $selectedTab) {  // sage active tint applied below
            NavigationStack {
                CookbooksGridView(jobs: jobs, cookbooks: cookbooks, auth: auth, userScope: userScope)
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
                KitchenTabView(jobs: jobs, cookbooks: cookbooks, userScope: userScope, sync: sync,
                               onSwitchToMealPlan: { selectedTab = .mealPlan })
            }
            .tabItem {
                Label("Kitchen", systemImage: "refrigerator")
            }
            .tag(Tab.kitchen)
        }
        // Sage is the app's only accent: active tab icon/label render sage; the
        // muted inactive colour comes from TabBarAppearance (UIKit) at launch.
        .tint(Color.accentColor)
        .task {
            jobs.reconcile()
            sync.triggerSync()  // pull remote changes + flush outbox on launch/sign-in
            await evaluateAppOpenPaywall()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                jobs.reconcile()
                sync.triggerSync()
                Task { await evaluateAppOpenPaywall() }
            case .background:
                // A share/import deep link applies only to the activation it opened.
                launchedFromShareThisActivation = false
            default:
                break
            }
        }
        // Launched via `recipeapp://` (Share Extension "Open RecipeApp"): bring
        // the user to the Recipes tab so the just-submitted job's processing card
        // is visible. The `.active` reconcile above then refreshes it.
        .onOpenURL { url in
            if url.scheme == "recipeapp" {
                launchedFromShareThisActivation = true
                selectedTab = .recipes
                jobs.reconcile()
            }
        }
        // Periodic app-open paywall (free users only, ≤ once / 3 days per account).
        // Presented here at the tab root; the paywall's visible close button lets the
        // user dismiss immediately and continue into the app.
        .sheet(isPresented: $showingAppOpenPaywall) {
            PlatterProPaywallView()
                .environmentObject(subscriptions)
        }
        // One-time failure modal, app-wide so it surfaces over whatever tab the
        // user is on when a live poll or foreground reconcile detects a failure.
        // Custom overlay (not a native .alert) so the OK button can be a filled
        // sage rectangle — native alerts only tint button text. The failed card
        // in the Recipes list remains for detailed review.
        .overlay {
            if let alert = jobs.failureAlert {
                FailureAlertView(
                    title: "Couldn’t add recipe",
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

    /// Decide whether to show the periodic app-open paywall. Ensures the account's
    /// server entitlement is resolved first (no flash for Pro), then applies the
    /// frequency cap and skip conditions (see `PaywallCadence`).
    @MainActor
    private func evaluateAppOpenPaywall() async {
        // Make sure the server entitlement for this account is resolved/refreshed
        // before deciding — this is idempotent after the first launch.
        await subscriptions.start()
        guard PaywallCadence.shouldPresentOnAppOpen(
            serverEntitlementResolved: subscriptions.serverEntitlementResolved,
            isPro: subscriptions.serverIsPro,
            lastShown: appOpenPaywallStore.lastShown(accountId: userScope),
            now: Date(),
            onboardingPaywallShownThisSession: subscriptions.onboardingPaywallShownThisSession,
            launchedFromShareOrImport: launchedFromShareThisActivation,
            importInProgress: !jobs.pending.isEmpty,
            purchaseInProgress: subscriptions.purchaseInProgress,
            anotherSheetPresented: showingAppOpenPaywall || jobs.failureAlert != nil || claimSummary != nil
        ) else { return }

        appOpenPaywallStore.recordShown(accountId: userScope, at: Date())
        showingAppOpenPaywall = true
    }
}

#Preview {
    MainTabView(
        recipeProvider: MockRecipeProvider(),
        auth: AuthModel(),
        subscriptions: SubscriptionService()
    )
    .environmentObject(SubscriptionService())
}
