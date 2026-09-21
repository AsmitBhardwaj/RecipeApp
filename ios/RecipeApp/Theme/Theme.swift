//
//  Theme.swift
//  RecipeApp
//
//  The single home for Platter's design tokens. Colour *roles* map to the
//  adaptive asset-catalog colour sets (the source of truth for light/dark);
//  spacing, the one corner radius, and the shared card treatment live here so
//  screens stop hard-coding values. Prefer these tokens over inline colours,
//  paddings and radii — new screens then inherit the same look for free.
//
//  Visual system:
//   • background  — flat pure white (light) / near-black (dark). No texture.
//   • surface     — cards and sheets: white with a 1px `hairline` border.
//   • hairline    — neutral warm-gray (#E8E6E1) card/divider stroke.
//   • creamTint   — the old cream (#F5ECDD), demoted to a subtle accent only
//                   (selected chips, grouped sections, empty-state panels).
//   • accent      — sage. Primary actions and selected states ONLY.
//

import SwiftUI

enum Theme {
    // MARK: Colour roles (adaptive; defined in Assets.xcassets)
    static let background = Color.appBackground     // flat white / near-black
    static let surface = Color.surface              // card + sheet fill
    static let hairline = Color.hairline            // 1px card border / divider
    static let creamTint = Color.creamTint          // subtle cream accent only
    static let textPrimary = Color.textPrimary      // ~#1C1B18
    static let textSecondary = Color.textSecondary  // muted clay-gray
    static let accent = Color.accentColor           // sage — primary + selected only

    // MARK: Corner radius — one value everywhere (cards, sheets, thumbnails).
    static let cornerRadius: CGFloat = 16

    // MARK: Spacing scale — 4 / 8 / 12 / 16 / 24 / 32.
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }
}
