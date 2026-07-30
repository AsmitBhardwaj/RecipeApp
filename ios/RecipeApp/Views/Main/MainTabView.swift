//
//  MainTabView.swift
//  RecipeApp
//
//  The tab shell: Recipes, Meal Plan, Grocery List (placeholder), and Discover
//  (placeholder). Account is reached from a toolbar icon on the Recipes screen,
//  not a tab. Grocery List and Discover are "coming soon" shells for now.
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
    @Environment(\.scenePhase) private var scenePhase

    init(recipeProvider: RecipeProvider) {
        _jobs = StateObject(wrappedValue: PendingJobsModel(provider: recipeProvider))
    }

    var body: some View {
        TabView {
            NavigationStack {
                RecipeListView(jobs: jobs)
            }
            .tabItem {
                Label("Recipes", systemImage: "book.closed.fill")
            }

            NavigationStack {
                MealPlanView(jobs: jobs)
            }
            .tabItem {
                Label("Meal Plan", systemImage: "calendar")
            }

            NavigationStack {
                GroceryListView(jobs: jobs)
            }
            .tabItem {
                Label("Grocery List", systemImage: "cart")
            }

            NavigationStack {
                DiscoverView()
            }
            .tabItem {
                Label("Discover", systemImage: "sparkles")
            }
        }
        .task { jobs.reconcile() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { jobs.reconcile() }
        }
        // One-time failure alert, app-wide so it surfaces over whatever tab the
        // user is on when a live poll or foreground reconcile detects a failure.
        // The failed card in the Recipes list remains for detailed review.
        .alert(
            "Couldn't add recipe",
            isPresented: Binding(
                get: { jobs.failureAlert != nil },
                set: { presented in if !presented { jobs.clearFailureAlert() } }
            ),
            presenting: jobs.failureAlert
        ) { _ in
            Button("OK", role: .cancel) { }
        } message: { alert in
            Text(alert.message)
        }
    }
}

#Preview {
    MainTabView(recipeProvider: MockRecipeProvider())
}
