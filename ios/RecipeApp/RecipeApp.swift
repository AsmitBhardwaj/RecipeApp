//
//  RecipeApp.swift
//  RecipeApp
//
//  App entry point. Constructs the single `RecipeProvider` and hands it to the
//  UI. The live app uses `APIRecipeProvider` (real backend); swap to
//  `MockRecipeProvider()` for offline/preview work.
//

import SwiftUI
import RecipeKit

@main
struct RecipeApp: App {
    /// The app-wide data source. Injected down into the views that need it.
    /// Live networking against the Railway backend.
    private let recipeProvider: RecipeProvider = APIRecipeProvider()

    init() {
        // Register the bundled editorial display font before any UI renders.
        AppFonts.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView(recipeProvider: recipeProvider)
        }
    }
}
