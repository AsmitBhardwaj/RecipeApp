//
//  GroceryListView.swift
//  RecipeApp
//
//  Placeholder for the Grocery List tab. No functionality yet (CLAUDE.md §2 lists
//  grocery lists as a later, paid-tier feature) — this is just the tab shell.
//

import SwiftUI

struct GroceryListView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Grocery List", systemImage: "cart")
        } description: {
            Text("Coming soon — build a shopping list from your planned recipes.")
        }
        .appBackground()
        .navigationTitle("Grocery List")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Grocery List")
                    .font(.editorialTitle(size: 22))
                    .foregroundStyle(Color.textPrimary)
            }
        }
    }
}

#Preview {
    NavigationStack {
        GroceryListView()
    }
}
