//
//  TornEdgeCard.swift
//  RecipeApp
//
//  The content-card treatment: a clean cream panel with a thin, warm-tan DASHED
//  border evoking a torn/perforated page edge. Sits on top of the textured cream
//  background so cards read as "clean paper on textured paper".
//
//  This is a CONTENT-card style only — recipe rows, meal-plan entries, the recipe
//  detail meta card. It is deliberately NOT applied to system chrome (sheets, nav
//  bars, the tab bar). The dashed color is the centralized `CardEdge` token
//  (#C7B892 light / muted tan dark), not a one-off hex.
//

import SwiftUI

struct TornEdgeCard: ViewModifier {
    var cornerRadius: CGFloat = 14
    var padding: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Color.appBackground, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(
                        Color.cardEdge,
                        style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])
                    )
            }
    }
}

extension View {
    /// Wraps content in the torn-edge cream card (see `TornEdgeCard`).
    func tornEdgeCard(cornerRadius: CGFloat = 14, padding: CGFloat = 14) -> some View {
        modifier(TornEdgeCard(cornerRadius: cornerRadius, padding: padding))
    }

    /// Torn-edge card for use as a `List` row: floats the card on the textured
    /// background by hiding the default separator/row fill and adding a gap.
    func tornEdgeCardRow(cornerRadius: CGFloat = 14) -> some View {
        self
            .tornEdgeCard(cornerRadius: cornerRadius)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }
}
