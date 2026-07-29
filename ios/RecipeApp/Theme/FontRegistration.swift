//
//  FontRegistration.swift
//  RecipeApp
//
//  Registers the bundled DM Serif Display faces at launch via Core Text. This
//  project uses GENERATE_INFOPLIST_FILE = YES (no physical Info.plist to add a
//  `UIAppFonts` array to), so programmatic registration is the robust path: it
//  needs no Info.plist/pbxproj changes and can't fall out of sync with the
//  bundled files. Call `AppFonts.register()` once, early, before any UI renders.
//

import CoreText
import Foundation

enum AppFonts {
    /// TTF resource names (without extension) bundled under RecipeApp/Fonts/.
    private static let bundled = ["DMSerifDisplay-Regular", "DMSerifDisplay-Italic"]

    static func register() {
        for name in bundled {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            // Ignore the "already registered" error so repeated calls are safe.
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
