//
//  MainTabView.swift
//  RecipeApp
//
//  The two-tab shell (CLAUDE.md §2): Recipes and Account.
//

import SwiftUI

struct MainTabView: View {
    let recipeProvider: RecipeProvider

    var body: some View {
        TabView {
            NavigationStack {
                RecipeListView(recipeProvider: recipeProvider)
            }
            .tabItem {
                Label("Recipes", systemImage: "book.closed.fill")
            }

            NavigationStack {
                AccountView()
            }
            .tabItem {
                Label("Account", systemImage: "person.crop.circle")
            }
        }
    }
}

#Preview {
    MainTabView(recipeProvider: MockRecipeProvider())
}
