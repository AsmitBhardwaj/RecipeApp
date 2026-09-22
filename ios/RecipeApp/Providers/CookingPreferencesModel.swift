import Foundation
import RecipeKit

@MainActor
final class CookingPreferencesModel: ObservableObject {
    @Published private(set) var preferences: CookingPreferences

    let userScope: String
    private let store: CookingPreferencesStore

    init(userScope: String, legacyCompletion: Bool = false) {
        self.userScope = userScope
        store = CookingPreferencesStore(userScope: userScope)
        if let stored = store.load() {
            preferences = stored
        } else {
            preferences = CookingPreferences(hasCompletedOnboarding: legacyCompletion)
            store.save(preferences)
        }
    }

    var primaryGoal: PrimaryCookingGoal? { preferences.primaryGoal }
    var dietaryPreferences: Set<DietaryPreference> { preferences.dietaryPreferences }
    var householdSize: Int { preferences.householdSize }
    var region: GroceryRegion? { preferences.region }
    var hasCompletedOnboarding: Bool { preferences.hasCompletedOnboarding }

    func saveAnswers(
        primaryGoal: PrimaryCookingGoal?,
        dietaryPreferences: Set<DietaryPreference>,
        householdSize: Int,
        region: GroceryRegion?
    ) {
        preferences = CookingPreferences(
            primaryGoal: primaryGoal,
            dietaryPreferences: dietaryPreferences,
            householdSize: householdSize,
            region: region,
            hasCompletedOnboarding: preferences.hasCompletedOnboarding
        )
        persist()
    }

    func updateGoal(_ goal: PrimaryCookingGoal?) {
        preferences.primaryGoal = goal
        persist()
    }

    func setDietaryPreference(_ preference: DietaryPreference, selected: Bool) {
        preferences.setDietaryPreference(preference, selected: selected)
        persist()
    }

    func updateHouseholdSize(_ size: Int) {
        preferences.householdSize = min(max(size, 1), 12)
        persist()
    }

    func updateRegion(_ region: GroceryRegion?) {
        preferences.region = region
        persist()
    }

    func completeOnboarding() {
        preferences.hasCompletedOnboarding = true
        persist()
        // Keep the former global flag in sync for a safe migration path from
        // builds that used @AppStorage directly.
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
    }

    func beginReplay() {
        preferences.hasCompletedOnboarding = false
        persist()
        UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
    }

    private func persist() {
        store.save(preferences)
    }
}
