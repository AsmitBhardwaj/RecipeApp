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
    ///
    /// Reserved for HEADERS: screen titles, section titles, and card/collection
    /// titles. Body text uses the system styles below, never this face.
    static func editorialTitle(size: CGFloat, relativeTo style: Font.TextStyle = .title) -> Font {
        .custom("DMSerifDisplay-Regular", size: size, relativeTo: style)
    }

    // MARK: - Body typography (system / San Francisco)
    //
    // The counterpart to `editorialTitle`: all non-title text (row titles,
    // ingredients, instructions, labels, subtitles, paragraphs) uses the system
    // font via Dynamic Type text styles — so it scales with the user's
    // accessibility text-size setting for free. These are the shared home for
    // body typography; prefer them (or the equivalent standard system text
    // styles) over inline custom fonts so new screens inherit the same treatment.

    /// Title of an item in a list/row (e.g. a recipe row). System, Dynamic Type —
    /// was DM Serif; switched so repeated list text stays legible and scales.
    static var appRowTitle: Font { .headline }
}
