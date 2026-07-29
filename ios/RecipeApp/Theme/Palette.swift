//
//  Palette.swift
//  RecipeApp
//
//  Home of the app's warm terracotta + cream theme helpers.
//
//  NOTE: the color accessors themselves (`Color.appBackground`, `.textPrimary`,
//  `.textSecondary`, `.secondaryAccent`, `.borderWarm`, `.badgeGenerated`) are
//  NOT declared here. The build setting
//  ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES makes Xcode
//  auto-generate a `Color` extension from each asset-catalog color set, so
//  declaring them again here caused "invalid redeclaration". The color sets in
//  Assets.xcassets are the single source of truth (each carries light + dark
//  variants); the primary accent stays `Color.accentColor` / `.tint` via the
//  `AccentColor` set. This file only adds the background convenience modifier.
//

import SwiftUI

extension View {
    /// Replaces the default system background of a screen with the warm cream
    /// app background. Hides the default scroll/list background so `List` and
    /// `Form` show cream rather than `systemGroupedBackground`.
    func appBackground() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Color.appBackground.ignoresSafeArea())
    }
}
