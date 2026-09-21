//
//  CardStyle.swift
//  RecipeApp
//
//  The shared content-card treatment: a flat `surface` panel with a single 1px
//  neutral `hairline` border and the one shared corner radius — no dashed/torn
//  page edge, no shadow. Replaces the old TornEdgeCard.
//
//  A CONTENT-card style only (recipe rows, meal-plan entries, the recipe detail
//  meta card). It is deliberately NOT applied to system chrome (sheets, nav
//  bars, the tab bar). Colours + radius come from `Theme`, never one-off values.
//

import SwiftUI

struct CardStyle: ViewModifier {
    var cornerRadius: CGFloat = Theme.cornerRadius
    var padding: CGFloat = Theme.Spacing.lg
    /// When false, the border is dropped (fill/radius/padding unchanged).
    var bordered: Bool = true

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                if bordered {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                }
            }
    }
}

extension View {
    /// Wraps content in the shared card (flat surface + 1px hairline border).
    /// `bordered: false` drops the border, leaving a plain surface panel.
    func card(cornerRadius: CGFloat = Theme.cornerRadius,
              padding: CGFloat = Theme.Spacing.lg,
              bordered: Bool = true) -> some View {
        modifier(CardStyle(cornerRadius: cornerRadius, padding: padding, bordered: bordered))
    }

    /// Card for use as a `List` row: hides the default separator/row fill and
    /// adds a gap so the card floats on the flat background.
    func cardRow(cornerRadius: CGFloat = Theme.cornerRadius, bordered: Bool = true) -> some View {
        self
            .card(cornerRadius: cornerRadius, bordered: bordered)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: Theme.Spacing.sm, leading: Theme.Spacing.lg,
                                      bottom: 0, trailing: Theme.Spacing.lg))
    }
}
