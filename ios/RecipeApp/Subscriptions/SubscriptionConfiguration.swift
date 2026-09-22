//
//  SubscriptionConfiguration.swift
//  RecipeApp
//
//  Single source of truth for Platter Pro product identifiers and legal URLs.
//

import Foundation

enum SubscriptionConfiguration {
    // DEVELOPMENT PLACEHOLDERS. Replace these two values with the exact
    // auto-renewable subscription product IDs created in App Store Connect
    // before shipping. Keep PlatterPro.storekit in sync with any change.
    static let monthlyProductID = "dev.platter.placeholder.pro.monthly"
    static let yearlyProductID = "dev.platter.placeholder.pro.yearly"

    static let productIDs: Set<String> = [monthlyProductID, yearlyProductID]
    static let orderedProductIDs = [yearlyProductID, monthlyProductID]

    // Apple standard EULA is the current Terms fallback. Replace with Platter's
    // own Terms URL if the product requires custom terms before release.
    static let termsURL = URL(
        string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"
    )!
    static let privacyURL = URL(string: "https://platterapp.tech/privacy")!
}
