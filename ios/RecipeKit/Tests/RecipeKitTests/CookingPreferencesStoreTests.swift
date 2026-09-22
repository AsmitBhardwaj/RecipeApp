import XCTest
@testable import RecipeKit

final class CookingPreferencesStoreTests: XCTestCase {
    func testRoundTripIsAccountScopedAndPersistsCompletion() {
        let suite = "CookingPreferencesStoreTests.\(#function)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = CookingPreferencesStore(defaults: defaults, userScope: "first")
        let second = CookingPreferencesStore(defaults: defaults, userScope: "second")
        first.save(CookingPreferences(
            primaryGoal: .useWhatIHave,
            dietaryPreferences: [.vegetarian, .dairyFree],
            householdSize: 4,
            hasCompletedOnboarding: true
        ))

        XCTAssertEqual(first.load()?.primaryGoal, .useWhatIHave)
        XCTAssertEqual(first.load()?.dietaryPreferences, [.vegetarian, .dairyFree])
        XCTAssertEqual(first.load()?.householdSize, 4)
        XCTAssertEqual(first.load()?.hasCompletedOnboarding, true)
        XCTAssertNil(second.load())
    }

    func testRegionRoundTripsThroughStore() {
        let suite = "CookingPreferencesStoreTests.\(#function)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = CookingPreferencesStore(defaults: defaults, userScope: "u")
        store.save(CookingPreferences(householdSize: 3, region: .sanFrancisco))
        XCTAssertEqual(store.load()?.region, .sanFrancisco)
        XCTAssertEqual(store.load()?.householdSize, 3)
    }

    func testPreferencesSavedBeforeRegionExistedStillDecode() {
        // A blob written by an older build has no "region" key; decoding must not
        // fail and region should come back nil.
        let legacy = #"{"dietaryPreferences":["vegan"],"householdSize":4,"hasCompletedOnboarding":true}"#
        let data = Data(legacy.utf8)
        let decoded = try? JSONDecoder().decode(CookingPreferences.self, from: data)
        XCTAssertNotNil(decoded)
        XCTAssertNil(decoded?.region)
        XCTAssertEqual(decoded?.householdSize, 4)
        XCTAssertEqual(decoded?.dietaryPreferences, [.vegan])
    }

    func testRegionApiValuesAreUniqueAndNormalized() {
        // Raw values are the exact server keys; they must be unique and already in
        // the strip().lower() normal form the backend matches on.
        let values = GroceryRegion.allCases.map(\.apiValue)
        XCTAssertEqual(Set(values).count, values.count, "duplicate region api values")
        for value in values {
            XCTAssertEqual(value, value.trimmingCharacters(in: .whitespaces).lowercased())
        }
    }

    func testLocaleGuessMapsCountriesAndDefaultsUSToNational() {
        XCTAssertEqual(GroceryRegion.guessFromLocale(Locale(identifier: "en_US")), .national)
        XCTAssertEqual(GroceryRegion.guessFromLocale(Locale(identifier: "en_CA")), .canada)
        XCTAssertEqual(GroceryRegion.guessFromLocale(Locale(identifier: "en_GB")), .unitedKingdom)
        XCTAssertEqual(GroceryRegion.guessFromLocale(Locale(identifier: "en_AU")), .australia)
        // A country with no offered bucket stays unselected.
        XCTAssertNil(GroceryRegion.guessFromLocale(Locale(identifier: "ja_JP")))
    }

    func testNoRestrictionsClearsOtherChoicesAndHouseholdIsClamped() {
        var preferences = CookingPreferences(householdSize: 99)
        preferences.setDietaryPreference(.vegan, selected: true)
        preferences.setDietaryPreference(.noRestrictions, selected: true)
        XCTAssertEqual(preferences.dietaryPreferences, [.noRestrictions])
        XCTAssertEqual(preferences.householdSize, 12)

        preferences.setDietaryPreference(.glutenFree, selected: true)
        XCTAssertEqual(preferences.dietaryPreferences, [.glutenFree])
    }
}
