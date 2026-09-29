import Foundation
import RecipeKit

@MainActor
final class CookingPreferencesModel: ObservableObject, SyncRefreshable {
    @Published private(set) var preferences: CookingPreferences
    /// Set (in memory only) when onboarding finishes so the main app opens Plan on
    /// a Budget and generates the first week from the quiz answers. Cleared once
    /// that generation has started.
    @Published private(set) var pendingPlanBuild = false

    let userScope: String
    private let store: CookingPreferencesStore
    /// Sync hub for the `cooking_preferences` collection. Attached once a signed-in
    /// coordinator exists (onboarding and the main tabs each own one); nil in
    /// previews/tests, in which case nothing is recorded.
    private var sync: SyncCoordinator?

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

    /// Wire up sync: local edits are recorded from now on, and a pull that lands new
    /// preferences (reinstall / another device) refreshes this model.
    func attachSync(_ coordinator: SyncCoordinator) {
        sync = coordinator
        coordinator.registerRefreshable(self)
    }

    /// Re-read the store after a sync pull wrote to it (the applier writes to disk,
    /// not to this model).
    func refreshFromStore() {
        guard let stored = store.load(), stored != preferences else { return }
        preferences = stored
    }

    func requestPlanBuild() { pendingPlanBuild = true }
    func consumePlanBuildRequest() { pendingPlanBuild = false }

    /// Persist a quiz draft (all answers at once). Onboarding completion is owned
    /// by `completeOnboarding`, never by a draft.
    func save(_ draft: CookingPreferences) {
        var updated = draft
        updated.hasCompletedOnboarding = preferences.hasCompletedOnboarding
        preferences = updated
        persist()
    }

    var primaryGoal: PrimaryCookingGoal? { preferences.primaryGoal }
    var dietaryPreferences: Set<DietaryPreference> { preferences.dietaryPreferences }
    var householdSize: Int { preferences.householdSize }
    var country: String? { preferences.country }
    var areaType: AreaType? { preferences.areaType }
    var hasCompletedOnboarding: Bool { preferences.hasCompletedOnboarding }
    var needsPlanSetup: Bool { preferences.needsPlanSetup }

    func saveAnswers(
        primaryGoal: PrimaryCookingGoal?,
        dietaryPreferences: Set<DietaryPreference>,
        householdSize: Int,
        country: String?,
        areaType: AreaType?
    ) {
        preferences = CookingPreferences(
            primaryGoal: primaryGoal,
            dietaryPreferences: dietaryPreferences,
            householdSize: householdSize,
            country: country,
            areaType: areaType,
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

    func updateCountry(_ country: String?) {
        preferences.country = country
        persist()
    }

    func updateAreaType(_ areaType: AreaType?) {
        preferences.areaType = areaType
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
        persist(recordSync: false)   // a local replay must not un-onboard the account elsewhere
        UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
    }

    private func persist(recordSync: Bool = true) {
        store.save(preferences)
        guard recordSync else { return }
        sync?.record(.cookingPreferences, itemId: CookingPreferences.syncItemId, payload: SyncCodec.encode(preferences))
    }
}
