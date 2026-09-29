//
//  BudgetGroceryListView.swift
//  RecipeApp
//
//  The plan's grocery list. Reuses GroceryAggregator and the existing grocery
//  row/section styling (GroceryCheckRow, cardRow, category headers) unchanged; the
//  only addition is a collapsed "Already in your pantry (N)" section on top for
//  items matched against the user's pantry. Matched items are moved, never deleted.
//

import SwiftUI
import RecipeKit

struct BudgetGroceryListView: View {
    let recipes: [Recipe]
    let pantryNames: [String]

    @Environment(\.dismiss) private var dismiss
    @State private var checked: Set<String> = []
    @State private var pantryExpanded = false

    private var split: GroceryPantryMatcher.Split {
        GroceryPantryMatcher.split(
            items: GroceryAggregator.aggregate(recipes: recipes),
            pantryNames: pantryNames
        )
    }

    private func sections(_ items: [GroceryLineItem]) -> [(GroceryCategory, [GroceryLineItem])] {
        let byCategory = Dictionary(grouping: items, by: { $0.category })
        return GroceryCategory.allCases.compactMap { category in
            guard let list = byCategory[category], !list.isEmpty else { return nil }
            return (category, list.sorted { $0.name.lowercased() < $1.name.lowercased() })
        }
    }

    var body: some View {
        let split = split
        NavigationStack {
            Group {
                if split.toBuy.isEmpty && split.inPantry.isEmpty {
                    emptyState
                } else {
                    list(split)
                }
            }
            .navigationTitle("Grocery list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .appBackground()
        }
    }

    private func list(_ split: GroceryPantryMatcher.Split) -> some View {
        List {
            if !split.inPantry.isEmpty {
                Section {
                    pantryHeaderRow(split)
                    if pantryExpanded {
                        ForEach(split.inPantry) { item in row(item, prefix: "pantry") }
                    }
                }
            }

            if split.toBuy.isEmpty {
                Section {
                    Text("Nothing to buy — your pantry covers this plan.")
                        .font(.subheadline)
                        .foregroundStyle(Color.textSecondary)
                        .cardRow(bordered: false)
                }
            }

            ForEach(sections(split.toBuy), id: \.0) { category, items in
                Section {
                    ForEach(items) { item in row(item, prefix: "buy") }
                } header: {
                    sectionHeader(category.displayName)
                }
            }
        }
        .listStyle(.plain)
    }

    private func row(_ item: GroceryLineItem, prefix: String) -> some View {
        let key = "\(prefix)|\(item.stableKey)"
        return GroceryCheckRow(
            text: item.displayString,
            detail: item.sources.joined(separator: ", "),
            icon: GroceryItemIconResolver.icon(for: item.name),
            checked: checked.contains(key)
        ) {
            if checked.contains(key) { checked.remove(key) } else { checked.insert(key) }
        }
        .cardRow(bordered: false)
    }

    /// Collapsed-by-default disclosure row: title with count, and the matched
    /// pantry names as its subtitle.
    private func pantryHeaderRow(_ split: GroceryPantryMatcher.Split) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) { pantryExpanded.toggle() }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Already in your pantry (\(split.inPantry.count))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.textPrimary)
                    Text(split.matchedPantryNames.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.textSecondary)
                    .rotationEffect(.degrees(pantryExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardRow(bordered: false)
        .accessibilityLabel("Already in your pantry, \(split.inPantry.count) items: \(split.matchedPantryNames.joined(separator: ", "))")
        .accessibilityValue(pantryExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Double-tap to \(pantryExpanded ? "collapse" : "expand")")
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.5)
            .foregroundStyle(Color.textSecondary)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("No ingredients yet")
                .font(.editorialTitle(size: 24, relativeTo: .title2))
                .foregroundStyle(Color.textPrimary)
            Text("This plan has no ingredient details to list.")
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
