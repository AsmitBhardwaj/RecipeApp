//
//  SplashView.swift
//  RecipeApp
//
//  Cold-launch splash: a static, full-screen sage-green field with the app icon
//  centered. No animation — it just holds while the app boots. RootView shows it
//  for a fixed interval, then crossfades to the main content.
//

import SwiftUI

struct SplashView: View {
    /// Brand green #637858.
    private static let brand = Color(red: 99 / 255, green: 120 / 255, blue: 88 / 255)
    private static let logoSize: CGFloat = 140
    private static let logoCorner: CGFloat = 24

    var body: some View {
        ZStack {
            Self.brand.ignoresSafeArea()

            // Full-resolution source artwork in its own imageset, NOT the app-icon
            // asset (which resolves only a small device-icon variant and looks soft
            // upscaled). `.interpolation(.high)` keeps the downscale crisp.
            Image("SplashLogo")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: Self.logoSize, height: Self.logoSize)
                .cornerRadius(Self.logoCorner)
                .accessibilityHidden(true)
        }
    }
}

#Preview {
    SplashView()
}
