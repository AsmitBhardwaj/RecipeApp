//
//  Typography.swift
//  RecipeApp
//
//  The single place the editorial display font is defined. DM Serif Display
//  (SIL OFL, bundled under RecipeApp/Fonts/ with its OFL.txt) is used ONLY as a
//  deliberate accent — page titles and recipe titles — never for body text, UI
//  chrome, or small labels. Everything else stays on the system sans font.
//
//  The font name string lives here and nowhere else, so swapping the display
//  face later is a one-line change.
//

import SwiftUI

extension Font {
    /// The editorial/cookbook display face (DM Serif Display). `relativeTo`
    /// keeps it scaling with Dynamic Type rather than pinning a fixed size.
    static func editorialTitle(size: CGFloat, relativeTo style: Font.TextStyle = .title) -> Font {
        .custom("DMSerifDisplay-Regular", size: size, relativeTo: style)
    }
}
