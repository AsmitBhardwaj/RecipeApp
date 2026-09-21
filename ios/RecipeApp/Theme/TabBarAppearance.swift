//
//  TabBarAppearance.swift
//  RecipeApp
//
//  One-time UIKit tab-bar styling, applied at launch so the SwiftUI `TabView`
//  keeps its native/floating shape but adopts the app palette:
//   • inactive icons + labels use the muted `textSecondary` role (never black),
//   • the active icon + label use the sage accent,
//   • SF Symbols render as templates (their default), so both states tint.
//
//  NOTE: the native tab bar's own selection capsule ("cream pill" in the design
//  spec) has no stable public API to recolour on the iOS 26 floating tab bar
//  without replacing it with a fully custom bar — which the spec explicitly rules
//  out ("keep native/floating style"). So the pill stays system-drawn; the sage
//  active tint is carried by the icon/label instead. See the change report.
//

import SwiftUI
import UIKit

enum TabBarAppearance {
    /// Configure the shared `UITabBar` appearance. Call once at launch, before the
    /// first tab bar renders.
    static func configure() {
        let appearance = UITabBarAppearance()
        // Keep the native translucent/floating background — no opaque fill.
        appearance.configureWithDefaultBackground()

        let item = UITabBarItemAppearance()

        // Inactive: muted, not black.
        let inactive = UIColor(Color.textSecondary)
        item.normal.iconColor = inactive
        item.normal.titleTextAttributes = [.foregroundColor: inactive]

        // Active: sage accent.
        let active = UIColor(Color.accentColor)
        item.selected.iconColor = active
        item.selected.titleTextAttributes = [.foregroundColor: active]

        appearance.stackedLayoutAppearance = item
        appearance.inlineLayoutAppearance = item
        appearance.compactInlineLayoutAppearance = item

        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
}
