//
//  GroceryRegion.swift
//  RecipeKit
//
//  The user's grocery-cost region, used by Plan on a Budget to pick a realistic
//  cost multiplier for a weekly budget.
//
//  IMPORTANT: each case's raw value is the exact key the backend expects, and MUST
//  stay in sync with `SELECTABLE_REGIONS` in app/pipeline/regional_cost.py. The
//  server matches case-insensitively after strip().lower(), and every key here is
//  a real bucket there — so a stored region never falls back to the 1.0 national
//  default by accident.
//

import Foundation

public enum GroceryRegion: String, Codable, CaseIterable, Hashable, Sendable {
    // High-cost US metros
    case sanFrancisco = "san francisco"
    case honolulu = "honolulu"
    case newYorkCity = "new york city"
    case boston = "boston"
    case seattle = "seattle"
    case losAngeles = "los angeles"
    case washingtonDC = "washington dc"
    case sanDiego = "san diego"
    case miami = "miami"
    case portland = "portland"
    // Mid / near-average
    case chicago = "chicago"
    case denver = "denver"
    case austin = "austin"
    case atlanta = "atlanta"
    // National baseline
    case national = "national"
    // Lower-cost US regions
    case dallas = "dallas"
    case phoenix = "phoenix"
    case houston = "houston"
    case south = "south"
    case midwest = "midwest"
    case rural = "rural"
    case ruralMidwest = "rural midwest"
    // Countries
    case australia = "australia"
    case unitedKingdom = "united kingdom"
    case canada = "canada"
    case mexico = "mexico"
    case india = "india"

    public var displayName: String {
        switch self {
        case .sanFrancisco: "San Francisco Bay Area"
        case .honolulu: "Honolulu"
        case .newYorkCity: "New York City"
        case .boston: "Boston"
        case .seattle: "Seattle"
        case .losAngeles: "Los Angeles"
        case .washingtonDC: "Washington, D.C."
        case .sanDiego: "San Diego"
        case .miami: "Miami"
        case .portland: "Portland"
        case .chicago: "Chicago"
        case .denver: "Denver"
        case .austin: "Austin"
        case .atlanta: "Atlanta"
        case .national: "United States (national average)"
        case .dallas: "Dallas"
        case .phoenix: "Phoenix"
        case .houston: "Houston"
        case .south: "U.S. South"
        case .midwest: "U.S. Midwest"
        case .rural: "Rural / small town"
        case .ruralMidwest: "Rural Midwest"
        case .australia: "Australia"
        case .unitedKingdom: "United Kingdom"
        case .canada: "Canada"
        case .mexico: "Mexico"
        case .india: "India"
        }
    }

    /// The string the client sends to the backend (== the raw value / server key).
    public var apiValue: String { rawValue }

    /// A coarse first guess from the device locale's country, used only to
    /// pre-select the picker. Country granularity can't distinguish US metros, so
    /// the US maps to the national average and the user refines from there. Returns
    /// nil when the country doesn't map to any offered bucket (picker stays empty).
    public static func guessFromLocale(_ locale: Locale = .current) -> GroceryRegion? {
        guard let code = localeRegionCode(locale)?.uppercased() else { return nil }
        switch code {
        case "US": return .national
        case "CA": return .canada
        case "GB", "UK": return .unitedKingdom
        case "AU": return .australia
        case "MX": return .mexico
        case "IN": return .india
        default: return nil
        }
    }

    private static func localeRegionCode(_ locale: Locale) -> String? {
        if #available(iOS 16, macOS 13, *) {
            return locale.region?.identifier
        } else {
            return locale.regionCode
        }
    }
}
