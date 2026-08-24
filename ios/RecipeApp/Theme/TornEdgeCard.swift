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
    /// When false, the solid card is drawn WITHOUT the dashed torn-edge border
    /// (fill/radius/padding are unchanged). Defaults to true so every existing
    /// caller keeps the torn-edge look.
    var bordered: Bool = true

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Color.appBackground, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                if bordered {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(
                            Color.cardEdge,
                            style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])
                        )
                }
            }
    }
}

extension View {
    /// Wraps content in the cream card. `bordered: false` drops the dashed
    /// torn-edge stroke, leaving a plain solid-background card.
    func tornEdgeCard(cornerRadius: CGFloat = 14, padding: CGFloat = 14, bordered: Bool = true) -> some View {
        modifier(TornEdgeCard(cornerRadius: cornerRadius, padding: padding, bordered: bordered))
    }

    /// Card for use as a `List` row: floats the card on the textured background by
    /// hiding the default separator/row fill and adding a gap. `bordered: false`
    /// drops the dashed torn-edge stroke.
    func tornEdgeCardRow(cornerRadius: CGFloat = 14, bordered: Bool = true) -> some View {
        self
            .tornEdgeCard(cornerRadius: cornerRadius, bordered: bordered)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }
}
