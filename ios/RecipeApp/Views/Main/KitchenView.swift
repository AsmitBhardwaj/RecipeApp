//
//  KitchenView.swift
//  RecipeApp
//
//  The Kitchen tab: a plain list of what the user has on hand (their "pantry").
//  Distilled from the "Added by you" portion of `GroceryListView` — same card /
//  list styling and the same add-field + swipe-to-delete affordances — but with
//  everything shopping-specific removed: no meal-plan derivation, no periods, no
//  checked/bought state. A pantry item isn't ticked off; removing it IS the
//  "used it up" action.
//
//  Names are stored verbatim (see `PantryModel.add`); any normalization for the
//  later recipe-suggestion feature happens at match time, not here.
//

import SwiftUI
import RecipeKit

struct KitchenView: View {
    @StateObject private var model: PantryModel

    @State private var showingAddItem = false
    @State private var newItemText = ""

    init(userScope: String? = nil, sync: SyncCoordinator? = nil) {
        _model = StateObject(wrappedValue: PantryModel(userScope: userScope, sync: sync))
    }

    var body: some View {
        content
            .foregroundStyle(Color.textPrimary)
            .appBackground()
            .navigationTitle("Kitchen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Kitchen")
                        .font(.editorialTitle(size: 22))
                        .foregroundStyle(Color.textPrimary)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddItem = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add item")
                }
            }
            .alert("Add to kitchen", isPresented: $showingAddItem) {
                TextField("e.g. olive oil", text: $newItemText)
                Button("Add") {
                    model.add(name: newItemText)
                    newItemText = ""
                }
                Button("Cancel", role: .cancel) { newItemText = "" }
            } message: {
                Text("Add something you have on hand.")
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.items.isEmpty {
            emptyState
        } else {
            List {
                Section {
                    ForEach(model.items) { item in
                        KitchenRow(
                            text: item.name,
                            icon: GroceryItemIconResolver.icon(for: item.name)
                        )
                        .tornEdgeCardRow(bordered: false)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                model.remove(item)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    sectionHeader("In your kitchen")
                }
            }
            .listStyle(.plain)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Your kitchen is empty", systemImage: "refrigerator")
        } description: {
            Text("Add what's in your kitchen so we can suggest recipes using it")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.5)
            .foregroundStyle(Color.textSecondary)
    }
}

// MARK: - Row (ingredient glyph + name; no checked-state affordance)

private struct KitchenRow: View {
    let text: String
    let icon: GroceryItemIcon

    var body: some View {
        HStack(spacing: 12) {
            IngredientIconGlyph(icon: icon, size: 30)
                .accessibilityHidden(true)

            Text(text)
                .font(.body)
                .foregroundStyle(Color.textPrimary)

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

#Preview {
    NavigationStack {
        KitchenView()
    }
}
