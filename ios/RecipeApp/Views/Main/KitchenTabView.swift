//
//  KitchenTabView.swift
//  RecipeApp
//
//  Container for the merged "Kitchen" tab. It owns the shared chrome — a large
//  serif "Kitchen" header with the segment's action buttons (share + add for
//  Grocery, add for Pantry), and the SINGLE segmented control ("Grocery list" |
//  "Pantry") — then embeds the active segment's view beneath it.
//
//  The header buttons drive the embedded child through bindings (`addPresented`,
//  `sharePresented`): the child still owns its models and presents its own
//  sheets/alerts from those bindings, so no view-model state moves up here. The
//  navigation bar is hidden (this view supplies its own header), and the children
//  run `embedded: true` so they suppress their own titles/toolbars.
//

import SwiftUI
import RecipeKit

struct KitchenTabView: View {
    @ObservedObject var jobs: PendingJobsModel
    /// The app's shared CookbooksModel, forwarded to the Pantry segment so its
    /// suggestion-detail sheet's "add to cookbook" uses the same instance as the
    /// Recipes tab (no duplicate model, no cross-tab desync).
    @ObservedObject var cookbooks: CookbooksModel
    let userScope: String
    let sync: SyncCoordinator
    /// Switches the app to the Meal Plan tab (grocery empty-state "Plan a meal").
    var onSwitchToMealPlan: () -> Void = {}

    private enum Segment: Hashable { case grocery, pantry }
    @State private var segment: Segment = .grocery

    // Header-button triggers, handed to the active child as bindings.
    @State private var groceryAddPresented = false
    @State private var grocerySharePresented = false
    @State private var pantryAddPresented = false
    /// Whether today's grocery list has anything to share — reported up from the
    /// Grocery segment so the header share button disables when there's nothing.
    @State private var groceryCanShare = false

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader("Kitchen") {
                if segment == .grocery {
                    CircleHeaderButton(systemImage: "square.and.arrow.up",
                                       disabled: !groceryCanShare,
                                       accessibilityLabel: "Share today's grocery list") {
                        grocerySharePresented = true
                    }
                    CircleHeaderButton(systemImage: "plus", primary: true,
                                       accessibilityLabel: "Add item") {
                        groceryAddPresented = true
                    }
                } else {
                    CircleHeaderButton(systemImage: "plus", primary: true,
                                       accessibilityLabel: "Add item") {
                        pantryAddPresented = true
                    }
                }
            }

            SegmentedPill(
                segments: [.init(title: "Grocery list", value: .grocery),
                           .init(title: "Pantry", value: .pantry)],
                selection: $segment
            )
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.bottom, Theme.Spacing.sm)

            switch segment {
            case .grocery:
                GroceryListView(jobs: jobs, userScope: userScope, sync: sync, embedded: true,
                                addPresented: $groceryAddPresented,
                                sharePresented: $grocerySharePresented,
                                onPlanMeal: onSwitchToMealPlan)
            case .pantry:
                KitchenView(cookbooks: cookbooks, userScope: userScope, sync: sync, embedded: true,
                            addPresented: $pantryAddPresented)
            }
        }
        .appBackground()
        .toolbar(.hidden, for: .navigationBar)
        .onPreferenceChange(GroceryCanSharePreferenceKey.self) { groceryCanShare = $0 }
    }
}

extension View {
    /// Applies `navigationTitle` only when `active`. Lets an embedded child view
    /// defer its title to an ancestor instead of stamping its own.
    @ViewBuilder
    func navigationTitle(_ title: String, active: Bool) -> some View {
        if active { self.navigationTitle(title) } else { self }
    }
}

#Preview {
    NavigationStack {
        KitchenTabView(
            jobs: PendingJobsModel(provider: MockRecipeProvider(), userScope: "preview"),
            cookbooks: CookbooksModel(),
            userScope: "preview",
            sync: SyncCoordinator(userId: "preview", tokenProvider: { "" })
        )
    }
    .environmentObject(SubscriptionService())
}
