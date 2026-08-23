//
//  GroceryShareText.swift
//  RecipeKit
//
//  Plain-text export of a day's grocery list, for the "Share Today's Grocery
//  List" feature. Pure (no UIKit) so it's unit-testable; the view derives the
//  items (meal-plan entries → recipes → GroceryAggregator) and passes the set it
//  wants to share (already filtered to unchecked items).
//
//  Format:
//
//    Platter — Grocery List for Sunday, Aug 23
//
//    Produce
//    - 2 onions
//    - garlic
//
//    Pantry
//    - 1 cup rice
//
//  Grouped by `GroceryCategory.allCases` order; empty categories are skipped.
//

import Foundation

public enum GroceryShareText {

    /// Section title for hand-added items, appended after the recipe categories.
    public static let manualSectionTitle = "Added by you"

    /// Builds the shareable plain-text list for `date` from `items`.
    ///
    /// - Parameters:
    ///   - items: the recipe-derived line items to share. Pass the already-filtered
    ///     set (e.g. unchecked only) — this function does not consult checked state.
    ///   - date: the day the list is for (used only for the header).
    ///   - manualItems: hand-added ("Added by you") item names, already filtered
    ///     (unchecked, today). Rendered as a final section in the given order;
    ///     omitted entirely when empty, like an empty category.
    ///   - locale: header locale (weekday/month names). Defaults to the device's.
    public static func build(
        items: [GroceryLineItem],
        for date: Date,
        manualItems: [String] = [],
        locale: Locale = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = "EEEE, MMM d"

        var lines: [String] = ["Platter — Grocery List for \(formatter.string(from: date))"]

        let byCategory = Dictionary(grouping: items, by: { $0.category })
        for category in GroceryCategory.allCases {
            guard let list = byCategory[category], !list.isEmpty else { continue }
            let sorted = list.sorted { $0.name.lowercased() < $1.name.lowercased() }
            lines.append("")               // blank line before each category block
            lines.append(category.displayName)
            for item in sorted {
                lines.append("- \(item.displayString)")
            }
        }

        // Hand-added items last, preserving caller order (the UI shows them
        // oldest-first). Skipped entirely when empty.
        if !manualItems.isEmpty {
            lines.append("")
            lines.append(manualSectionTitle)
            for name in manualItems {
                lines.append("- \(name)")
            }
        }

        return lines.joined(separator: "\n")
    }
}
