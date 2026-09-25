//
//  SubscriptionConfiguration.swift
//  RecipeApp
//
//  Single source of truth for Platter Pro product identifiers and legal URLs.
//

import Foundation

enum SubscriptionConfiguration {
    // The live auto-renewable subscription product IDs, created in App Store
    // Connect. Keep PlatterPro.storekit in sync with any change to these.
    static let monthlyProductID = "com.recipeapp.RecipeApp2.pro.monthly"
    static let yearlyProductID = "com.recipeapp.RecipeApp2.pro.yearly"

    static let productIDs: Set<String> = [monthlyProductID, yearlyProductID]
    static let orderedProductIDs = [yearlyProductID, monthlyProductID]

    // Apple standard EULA is the current Terms fallback. Replace with Platter's
    // own Terms URL if the product requires custom terms before release.
    static let termsURL = URL(
        string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"
    )!
    static let privacyURL = URL(string: "https://platterapp.tech/privacy")!
}
