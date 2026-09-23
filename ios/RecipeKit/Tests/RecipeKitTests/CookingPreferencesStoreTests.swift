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

    func testCountryAndAreaTypeRoundTripThroughStore() {
        let suite = "CookingPreferencesStoreTests.\(#function)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = CookingPreferencesStore(defaults: defaults, userScope: "u")
        store.save(CookingPreferences(householdSize: 3, country: "US", areaType: .city))
        XCTAssertEqual(store.load()?.country, "US")
        XCTAssertEqual(store.load()?.areaType, .city)
        XCTAssertEqual(store.load()?.householdSize, 3)
    }

    func testPreferencesSavedBeforeLocationExistedStillDecode() {
        // A blob written by an older build has no country/area_type keys; decoding
        // must not fail and both should come back nil.
        let legacy = #"{"dietaryPreferences":["vegan"],"householdSize":4,"hasCompletedOnboarding":true}"#
        let data = Data(legacy.utf8)
        let decoded = try? JSONDecoder().decode(CookingPreferences.self, from: data)
        XCTAssertNotNil(decoded)
        XCTAssertNil(decoded?.country)
        XCTAssertNil(decoded?.areaType)
        XCTAssertEqual(decoded?.householdSize, 4)
        XCTAssertEqual(decoded?.dietaryPreferences, [.vegan])
    }

    func testLegacyRegionFieldIsIgnoredOnDecode() {
        // A blob from before this change carried a single "region" key. Decoding
        // must succeed and simply drop it — the user re-picks country + area type.
        let legacy = #"{"householdSize":2,"region":"san francisco","hasCompletedOnboarding":true}"#
        let decoded = try? JSONDecoder().decode(CookingPreferences.self, from: Data(legacy.utf8))
        XCTAssertNotNil(decoded)
        XCTAssertNil(decoded?.country)
        XCTAssertNil(decoded?.areaType)
    }

    func testAreaTypeApiValuesAreNormalized() {
        // Raw values are the exact server keys the backend matches on (strip().lower()).
        for area in AreaType.allCases {
            XCTAssertEqual(area.apiValue, area.apiValue.trimmingCharacters(in: .whitespaces).lowercased())
        }
        XCTAssertEqual(Set(AreaType.allCases.map(\.apiValue)), ["city", "suburb", "rural"])
    }

    func testCountryLocaleGuessReturnsISOCode() {
        XCTAssertEqual(GroceryCountry.guessFromLocale(Locale(identifier: "en_US")), "US")
        XCTAssertEqual(GroceryCountry.guessFromLocale(Locale(identifier: "en_GB")), "GB")
        XCTAssertEqual(GroceryCountry.guessFromLocale(Locale(identifier: "ja_JP")), "JP")
    }

    func testCountryListIsNonEmptyAndNamed() {
        let all = GroceryCountry.all(locale: Locale(identifier: "en_US"))
        XCTAssertFalse(all.isEmpty)
        XCTAssertTrue(all.contains { $0.code == "US" && $0.name == "United States" })
        XCTAssertTrue(all.contains { $0.code == "IN" })
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
