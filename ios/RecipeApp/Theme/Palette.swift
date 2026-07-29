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
    /// app background, plus a very subtle tiled paper-grain texture. Hides the
    /// default scroll/list background so `List` and `Form` show cream rather than
    /// `systemGroupedBackground`.
    ///
    /// The grain is the single, app-wide texture seam: it lives strictly BEHIND
    /// content here (never on cards, buttons, or text), tiles a light/dark
    /// `PaperGrain` asset at low opacity, and never intercepts touches.
    func appBackground() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background {
                Color.appBackground
                    .overlay {
                        Image("PaperGrain")
                            .resizable(resizingMode: .tile)
                            .opacity(0.6)
                            .allowsHitTesting(false)
                    }
                    .ignoresSafeArea()
            }
    }
}
