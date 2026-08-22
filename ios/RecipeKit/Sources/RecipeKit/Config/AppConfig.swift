//
//  AppConfig.swift
//  RecipeKit
//
//  Build-time app configuration read from the main bundle's Info.plist.
//
//  The `APP_KEY` value is a static shared secret the backend requires on every
//  request (`X-App-Key`) as abuse deterrence for the public beta endpoint. It is
//  NOT real authentication — a secret shipped inside an app binary is
//  extractable by anyone who unpacks the IPA. It only raises the bar against
//  casual/scripted hits on the open endpoint; rotate it (new value + app update)
//  if it leaks.
//
//  Because this repo is public, the literal value is NOT committed. It is
//  injected at build time from a gitignored `ios/Secrets.xcconfig`
//  (`APP_KEY = ...`), which is wired as the RecipeApp target's base
//  configuration. The committed `ios/RecipeApp-Info.plist` (INFOPLIST_FILE)
//  carries `APP_KEY = $(APP_KEY)`, which Xcode expands from that build setting
//  and merges into the app's Info.plist, where this reads it at runtime.
//  (A custom `INFOPLIST_KEY_APP_KEY` build setting does NOT work — Xcode only
//  maps its own known INFOPLIST_KEY_* keys into a generated plist.) When unset
//  (dev builds with no Secrets.xcconfig), `appKey` is empty and the networking
//  layer simply omits the header.
//

import Foundation

public enum AppConfig {
    /// The shared app key, or "" when not configured for this build.
    public static var appKey: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "APP_KEY") as? String
        return (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
