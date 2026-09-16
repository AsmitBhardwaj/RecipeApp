//
//  KitchenTabView.swift
//  RecipeApp
//
//  Container for the merged "Kitchen" tab: the former standalone Grocery List
//  and Kitchen (Pantry) tabs, now switched by a segmented picker at the top
//  ("Grocery List" | "Pantry", Grocery List default).
//
//  UI-shell ONLY. Each segment embeds the existing view unchanged, so their view
//  models, checked/sync state, and sync collections (grocery_manual /
//  grocery_check for the list, pantry_items for the pantry) are untouched. The
//  embedded views keep supplying their own nav-bar chrome (title + add button)
//  via the ambient NavigationStack that MainTabView wraps this container in — so
//  this view adds no NavigationStack of its own.
//
//  Note: the two segments are swapped with an if/else (not held side-by-side),
//  because each embedded view declares its own principal title + toolbar and
//  keeping both mounted would put two competing titles/add-buttons in one nav
//  bar. A consequence is that a segment's transient view state (e.g. the grocery
//  list's day/week scope) is recreated when you switch away and back — see the
//  report accompanying this change.
//

import SwiftUI
import RecipeKit

struct KitchenTabView: View {
    @ObservedObject var jobs: PendingJobsModel
    let userScope: String
    let sync: SyncCoordinator

    private enum Segment: Hashable { case grocery, pantry }
    @State private var segment: Segment = .grocery

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $segment) {
                Text("Grocery List").tag(Segment.grocery)
                Text("Pantry").tag(Segment.pantry)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 4)

            switch segment {
            case .grocery:
                GroceryListView(jobs: jobs, userScope: userScope, sync: sync, embedded: true)
            case .pantry:
                KitchenView(userScope: userScope, sync: sync, embedded: true)
            }
        }
        .appBackground()
        // Consistent container title regardless of the active segment. The
        // children are `embedded: true`, so they suppress their own principal
        // title + navigationTitle and defer to this one (see their `embedded`
        // flag). Rendered as a principal item in the app's editorial font to
        // match the look the children previously had.
        .navigationTitle("Kitchen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Kitchen")
                    .font(.editorialTitle(size: 22))
                    .foregroundStyle(Color.textPrimary)
            }
        }
    }
}

extension View {
    /// Applies `navigationTitle` only when `active`. Lets an embedded child view
    /// defer its title to an ancestor (KitchenTabView) instead of stamping its
    /// own — a deeper `.navigationTitle` would otherwise override the container's.
    @ViewBuilder
    func navigationTitle(_ title: String, active: Bool) -> some View {
        if active { self.navigationTitle(title) } else { self }
    }
}

#Preview {
    NavigationStack {
        KitchenTabView(
            jobs: PendingJobsModel(provider: MockRecipeProvider(), userScope: "preview"),
            userScope: "preview",
            sync: SyncCoordinator(userId: "preview", tokenProvider: { "" })
        )
    }
}
