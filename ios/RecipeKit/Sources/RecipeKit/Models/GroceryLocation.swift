//
//  GroceryLocation.swift
//  RecipeKit
//
//  The user's grocery-cost location for Plan on a Budget, captured as two
//  structured signals that replace the old single free-region enum:
//
//    * country  — an ISO 3166-1 alpha-2 code (e.g. "US"), chosen from a
//      searchable list of all countries. Stored as the raw code string.
//    * areaType — City / Suburb / Rural (single select).
//
//  The backend combines them into one multiplier:
//      multiplier = country_baseline(country) × area_modifier(areaType)
//  (see app/pipeline/regional_cost.py). Unknown/unset parts fall back to 1.0.
//
//  IMPORTANT: `AreaType`'s raw values are the exact keys the backend matches on
//  (strip().lower()) and MUST stay in sync with `AREA_MODIFIERS` in
//  app/pipeline/regional_cost.py. Country codes are standard ISO alpha-2, so the
//  server keys on them directly (uppercased) — unlisted countries just resolve to
//  the 1.0 default baseline.
//

import Foundation

/// How dense the user's area is — nudges the country baseline up (city) or down
/// (rural), with suburb as the 1.0 anchor.
public enum AreaType: String, Codable, CaseIterable, Hashable, Sendable {
    case city
    case suburb
    case rural

    public var displayName: String {
        switch self {
        case .city: "City"
        case .suburb: "Suburb"
        case .rural: "Rural"
        }
    }

    /// A one-line hint shown under each option in the picker.
    public var detail: String {
        switch self {
        case .city: "Denser, pricier groceries"
        case .suburb: "Around the national average"
        case .rural: "Smaller town, usually cheaper"
        }
    }

    /// The string the client sends to the backend (== the raw value / server key).
    public var apiValue: String { rawValue }
}

/// Lookup helpers for the searchable country picker. Country data comes from the
/// OS (ISO 3166-1 alpha-2), so there is no hardcoded country table to maintain —
/// the backend applies a real cost baseline for the ones it knows and a 1.0
/// default for the rest.
public enum GroceryCountry {

    /// Every ISO alpha-2 country code paired with its localized name, sorted by
    /// name in the given locale. Codes with no localized name are dropped.
    public static func all(locale: Locale = .current) -> [(code: String, name: String)] {
        isoCountryCodes(locale)
            .compactMap { code in
                guard let name = localizedName(for: code, locale: locale) else { return nil }
                return (code, name)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The localized display name for an ISO alpha-2 country code, or nil if the
    /// code has no name in this locale.
    public static func localizedName(for code: String, locale: Locale = .current) -> String? {
        locale.localizedString(forRegionCode: code.uppercased())
    }

    /// A coarse first guess from the device locale's country, used only to
    /// pre-select the picker. Returns the uppercased ISO code, or nil.
    public static func guessFromLocale(_ locale: Locale = .current) -> String? {
        currentRegionCode(locale)?.uppercased()
    }

    // MARK: - OS plumbing

    private static func isoCountryCodes(_ locale: Locale) -> [String] {
        if #available(iOS 16, macOS 13, *) {
            // `isoRegions` includes continents/subdivisions; ISO 3166-1 country
            // codes are exactly the two-letter alphabetic identifiers.
            return Locale.Region.isoRegions
                .map(\.identifier)
                .filter { $0.count == 2 && $0.allSatisfy(\.isLetter) }
        } else {
            return Locale.isoRegionCodes.filter { $0.count == 2 && $0.allSatisfy(\.isLetter) }
        }
    }

    private static func currentRegionCode(_ locale: Locale) -> String? {
        if #available(iOS 16, macOS 13, *) {
            return locale.region?.identifier
        } else {
            return locale.regionCode
        }
    }
}
