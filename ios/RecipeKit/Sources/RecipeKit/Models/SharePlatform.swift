//
//  SharePlatform.swift
//  RecipeKit
//
//  The source platform of a shared link, derived purely from its URL host. Used
//  by the client to show a source icon on a processing card the instant a share
//  is queued — before the backend has resolved the job and reported its own
//  `platform`. The classification mirrors the backend's `urls.py`:
//    tiktok.com (incl. vm./vt. shortlinks) → tiktok
//    instagram.com / instagr.am            → instagram
//    anything else                         → web
//
//  Kept as pure, UI-free logic here so it can be unit-tested and reused; the
//  mapping to an actual SF Symbol / label lives in the app layer.
//

import Foundation

public enum SharePlatform: String, Codable, Hashable, Sendable, CaseIterable {
    case instagram
    case tiktok
    case web

    /// Classify a raw URL string by host. Anything that doesn't parse to a host,
    /// or whose host matches neither video platform, is treated as generic `web`
    /// (the same bucket the backend uses for recipe blogs).
    public init(url: String) {
        let host = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines))?
            .host?
            .lowercased() ?? ""

        if host.contains("tiktok.com") {
            self = .tiktok
        } else if host.contains("instagram.com") || host.contains("instagr.am") {
            self = .instagram
        } else {
            self = .web
        }
    }
}
