//
//  RecipeProvider.swift
//  RecipeApp
//
//  The single seam between the UI and its data source.
//
//  Views never construct recipes directly — they read them through a
//  `RecipeProvider`. Today the only conformance is `MockRecipeProvider`.
//  Wiring up the real backend later means adding one `APIRecipeProvider`
//  conformance and changing the provider passed in at the app root; no view
//  needs to change.
//
//  `async throws` is used now even though the mock returns instantly, so the
//  method signature won't change when a real networked implementation lands.
//

import Foundation
import RecipeKit

protocol RecipeProvider {
    /// The user's saved recipes. Backed by mock data today; will be a network
    /// fetch of the user's vault later.
    func fetchRecipes() async throws -> [Recipe]
}
