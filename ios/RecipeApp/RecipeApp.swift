//
//  RecipeApp.swift
//  RecipeApp
//
//  App entry point. Constructs the single `RecipeProvider` (mock today) and
//  hands it to the UI. This constructor call is the one place that changes
//  when the real backend is wired up: swap `MockRecipeProvider()` for an
//  `APIRecipeProvider(...)`.
//

import SwiftUI

@main
struct RecipeApp: App {
    /// The app-wide data source. Injected down into the views that need it.
    private let recipeProvider: RecipeProvider = MockRecipeProvider()

    var body: some Scene {
        WindowGroup {
            RootView(recipeProvider: recipeProvider)
        }
    }
}
