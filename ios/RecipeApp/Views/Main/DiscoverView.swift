//
//  DiscoverView.swift
//  RecipeApp
//
//  Placeholder for the Discover tab. This will need real backend work later
//  (suggested recipes from other users' vaults — CLAUDE.md §2, "later, needs
//  real usage data first"), so nothing functional is built here yet.
//

import SwiftUI

struct DiscoverView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Discover", systemImage: "sparkles")
        } description: {
            Text("Coming soon — find recipes shared by the community.")
        }
        .navigationTitle("Discover")
    }
}

#Preview {
    NavigationStack {
        DiscoverView()
    }
}
