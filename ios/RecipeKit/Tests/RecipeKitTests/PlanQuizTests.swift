//
//  PlanQuizTests.swift
//  RecipeKitTests
//
//  Stage 2 (onboarding quiz): diet exclusivity, the mood cap, hotspot hit
//  testing, store → tier, the budget helper math, the preferences sync
//  round-trip, the existing-user setup trigger, and "New plan" pre-fill.
//

import XCTest
@testable import RecipeKit

final class PlanQuizTests: XCTestCase {

    private func onboarding(_ prefs: CookingPreferences = CookingPreferences()) -> PlanQuizSession {
        .onboarding(from: prefs, deviceCountry: "US")
    }

    // MARK: Diet

    func testDietDefaultsToNoRestrictions() {
        XCTAssertEqual(onboarding().draft.dietaryPreferences, [.noRestrictions])
        XCTAssertTrue(onboarding().isValid(.diet))
    }

    func testNoRestrictionsIsExclusiveWithOthers() {
        var s = onboarding()
        s.toggleDiet(.vegan)
        s.toggleDiet(.glutenFree)
        XCTAssertEqual(s.draft.dietaryPreferences, [.vegan, .glutenFree])   // "No restrictions" dropped
        s.toggleDiet(.noRestrictions)
        XCTAssertEqual(s.draft.dietaryPreferences, [.noRestrictions])       // clears the others
        s.toggleDiet(.halal)
        XCTAssertEqual(s.draft.dietaryPreferences, [.halal])
    }

    func testDeselectingLastRestrictionFallsBackToNoRestrictions() {
        var s = onboarding()
        s.toggleDiet(.kosher)
        s.toggleDiet(.kosher)
        XCTAssertEqual(s.draft.dietaryPreferences, [.noRestrictions])
        s.toggleDiet(.noRestrictions)                                       // can't be toggled to empty
        XCTAssertEqual(s.draft.dietaryPreferences, [.noRestrictions])
    }

    func testDietOptionsOrderAndNewCases() {
        XCTAssertEqual(DietaryPreference.allCases.map(\.displayName), [
            "No restrictions", "Vegetarian", "Vegan", "Pescatarian", "Gluten-free",
            "Dairy-free", "Halal", "Kosher", "Nut-free",
        ])
    }

    // MARK: Food mood (max 3, optional)

    func testMoodCapsAtThree() {
        var s = onboarding()
        XCTAssertTrue(s.isValid(.mood))                        // 0 is valid
        XCTAssertTrue(s.toggleMood(.comfort))
        XCTAssertTrue(s.toggleMood(.spicy))
        XCTAssertTrue(s.toggleMood(.quick))
        XCTAssertFalse(s.toggleMood(.adventurous))             // 4th refused
        XCTAssertEqual(s.draft.foodMoods, [.comfort, .spicy, .quick])
        XCTAssertTrue(s.toggleMood(.spicy))                    // deselect always works
        XCTAssertTrue(s.toggleMood(.adventurous))              // and frees a slot
        XCTAssertEqual(s.draft.orderedFoodMoods, [.comfort, .quick, .adventurous])
    }

    func testMoodRawValuesMatchServerEnum() {
        XCTAssertEqual(FoodMood.allCases.map(\.rawValue),
                       ["comfort", "light_fresh", "spicy", "quick", "adventurous", "high_protein"])
        XCTAssertEqual(FoodMood.lightFresh.assetName, "mood_light_fresh")
    }

    // MARK: Appliances

    func testApplianceRequiresAtLeastOneAndRawValuesMatchServer() {
        var s = PlanQuizSession.planSetup(from: CookingPreferences(hasCompletedOnboarding: true), deviceCountry: nil)
        s.advance()                                            // mood → appliances
        XCTAssertEqual(s.step, .appliances)
        XCTAssertFalse(s.canContinue)
        s.toggleAppliance(.airFryer)
        XCTAssertTrue(s.canContinue)
        s.toggleAppliance(.airFryer)
        XCTAssertFalse(s.canContinue)
        XCTAssertEqual(Appliance.allCases.map(\.rawValue), [
            "stovetop", "oven", "microwave", "air_fryer", "slow_cooker", "rice_cooker", "blender", "kettle",
        ])
    }

    // MARK: Hotspots

    func testHotspotTableCoversAllEightAppliancesInsideTheImage() {
        XCTAssertEqual(Set(KitchenHotspots.table.map(\.appliance)), Set(Appliance.allCases))
        XCTAssertEqual(KitchenHotspots.table.count, 8)
        for spot in KitchenHotspots.table {
            XCTAssertGreaterThanOrEqual(spot.rect.x, 0)
            XCTAssertGreaterThanOrEqual(spot.rect.y, 0)
            XCTAssertLessThanOrEqual(spot.rect.x + spot.rect.width, 1)
            XCTAssertLessThanOrEqual(spot.rect.y + spot.rect.height, 1)
        }
    }

    func testHitTestingHitsEachRectCenterAndMissesOutside() {
        for spot in KitchenHotspots.table {
            XCTAssertEqual(KitchenHotspots.appliance(atNormalized: spot.rect.centerX, spot.rect.centerY), spot.appliance)
        }
        XCTAssertNil(KitchenHotspots.appliance(atNormalized: 0.0, 0.0))
        XCTAssertNil(KitchenHotspots.appliance(atNormalized: 1.0, 1.0))
        XCTAssertNil(KitchenHotspots.appliance(atNormalized: -0.1, 0.5))
    }

    func testHitTestingScalesWithRenderedSize() {
        let spot = KitchenHotspots.table[0]
        for size in [CGSize(width: 300, height: 225), CGSize(width: 1024, height: 768), CGSize(width: 90, height: 70)] {
            let frame = spot.rect.frame(in: size)
            let center = CGPoint(x: frame.midX, y: frame.midY)
            XCTAssertEqual(KitchenHotspots.appliance(at: center, in: size), spot.appliance)
        }
        XCTAssertNil(KitchenHotspots.appliance(at: CGPoint(x: 5, y: 5), in: .zero))
    }

    func testOverlappingRectsPickTheSmallestAndEdgesAreHalfOpen() {
        let big = NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5)
        let small = NormalizedRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1)
        XCTAssertTrue(big.contains(x: 0, y: 0))
        XCTAssertFalse(big.contains(x: 0.5, y: 0.25))          // right edge excluded
        XCTAssertLessThan(small.area, big.area)
        let frame = small.frame(in: CGSize(width: 200, height: 100))
        XCTAssertEqual(frame, CGRect(x: 20, y: 10, width: 20, height: 10))
    }

    // MARK: Store → tier

    func testStoreTierMapping() {
        for name in ["Aldi", "Walmart", "Lidl"] { XCTAssertEqual(PlanStore.tier(forStoreName: name), .budget, name) }
        for name in ["Kroger", "Target", "Trader Joe's", "Costco", "Other"] {
            XCTAssertEqual(PlanStore.tier(forStoreName: name), .standard, name)
        }
        XCTAssertEqual(PlanStore.tier(forStoreName: "Whole Foods"), .premium)
        XCTAssertEqual(PlanStore.tier(forStoreName: "Some Corner Shop"), .standard)
    }

    func testStoreGridIsNineTilesWithPriceHints() {
        XCTAssertEqual(PlanStore.all.map(\.name), [
            "Aldi", "Walmart", "Lidl", "Kroger", "Target", "Trader Joe's", "Costco", "Whole Foods", "Other",
        ])
        XCTAssertEqual(PlanStore.all.map(\.priceHint), ["$", "$", "$", "$$", "$$", "$$", "$$", "$$$", ""])
    }

    func testSelectingStoreStoresNameAndSendsTier() {
        var s = onboarding()
        XCTAssertFalse(s.isValid(.store))
        s.selectStore(PlanStore.named("Whole Foods")!)
        XCTAssertEqual(s.draft.storeName, "Whole Foods")
        XCTAssertEqual(s.draft.planOptions.storeTier, "premium")
        XCTAssertTrue(s.isValid(.store))
    }

    func testOtherHasNoShopperLabel() {
        XCTAssertNil(PlanStore.named("Other")?.shopperLabel)
        XCTAssertEqual(PlanStore.named("Other")?.helperName, "your store")
        XCTAssertEqual(PlanStore.named("Aldi")?.shopperLabel, "Aldi")
    }

    // MARK: Budget helper

    func testTypicalSpendMath() {
        // $5.50 / $8 per person per dinner × 7 × people × multiplier, nearest $5.
        XCTAssertEqual(PlanBudgetHelper.typicalSpend(people: 1, multiplier: 1), .init(low: 40, high: 55))   // 38.5, 56
        XCTAssertEqual(PlanBudgetHelper.typicalSpend(people: 2, multiplier: 1), .init(low: 75, high: 110))  // 77, 112
        XCTAssertEqual(PlanBudgetHelper.typicalSpend(people: 4, multiplier: 1), .init(low: 155, high: 225)) // 154, 224
        XCTAssertEqual(PlanBudgetHelper.typicalSpend(people: 2, multiplier: 0.85), .init(low: 65, high: 95)) // 65.45, 95.2
        XCTAssertEqual(PlanBudgetHelper.typicalSpend(people: 2, multiplier: 1.3), .init(low: 100, high: 145)) // 100.1, 145.6
    }

    func testBoundsScaleWithMultiplierAndNeverUndercutTheServerFloor() {
        XCTAssertEqual(PlanBudgetHelper.bounds(people: 2, multiplier: 1),
                       BudgetMath.minBudget(householdSize: 2)...BudgetMath.maxBudget(householdSize: 2))
        for people in 1...12 {
            for m in [0.55, 0.7, 0.85, 1.0, 1.3, 1.45 * 1.3] {
                let r = PlanBudgetHelper.bounds(people: people, multiplier: m)
                XCTAssertGreaterThanOrEqual(Double(r.lowerBound) / m, Double(BudgetMath.minBudget(householdSize: people)) - 1e-9)
                XCTAssertLessThanOrEqual(Double(r.upperBound) / m, Double(BudgetMath.maxBudget(householdSize: people)) + 1e-9)
                XCTAssertEqual(r.lowerBound % 5, 0)
                XCTAssertEqual(r.upperBound % 5, 0)
                XCTAssertLessThan(r.lowerBound, r.upperBound)
            }
        }
    }

    func testDefaultBudgetIsLowClampedToBounds() {
        XCTAssertEqual(PlanBudgetHelper.defaultBudget(people: 2, multiplier: 1), 75)
        // 1 person: low 40 is inside 10…85 → 40.
        XCTAssertEqual(PlanBudgetHelper.defaultBudget(people: 1, multiplier: 1), 40)
        // Always inside the bounds, and equal to the typical low end when that fits.
        for people in 1...12 {
            for m in [0.55, 0.85, 1.0, 1.3, 1.89] {
                let bounds = PlanBudgetHelper.bounds(people: people, multiplier: m)
                let low = PlanBudgetHelper.typicalSpend(people: people, multiplier: m).low
                let d = PlanBudgetHelper.defaultBudget(people: people, multiplier: m)
                XCTAssertTrue(bounds.contains(d))
                if bounds.contains(low) { XCTAssertEqual(d, low) }
            }
        }
        // The clamp itself: an out-of-range value snaps to the nearest bound.
        let b = PlanBudgetHelper.bounds(people: 2, multiplier: 1)
        XCTAssertEqual(PlanBudgetHelper.clamp(b.lowerBound - 50, people: 2, multiplier: 1), b.lowerBound)
        XCTAssertEqual(PlanBudgetHelper.clamp(b.upperBound + 50, people: 2, multiplier: 1), b.upperBound)
    }

    func testMultiplierMirrorsServerTable() {
        XCTAssertEqual(RegionalCostMultiplier.multiplier(country: "US", storeTier: .standard), 1.0)
        XCTAssertEqual(RegionalCostMultiplier.multiplier(country: "US", storeTier: .budget), 0.85)
        XCTAssertEqual(RegionalCostMultiplier.multiplier(country: "us", storeTier: .premium), 1.3)
        XCTAssertEqual(RegionalCostMultiplier.multiplier(country: "CH", storeTier: .premium), 1.89)   // 1.45 × 1.30 = 1.885 → 1.89
        XCTAssertEqual(RegionalCostMultiplier.multiplier(country: "ZZ", storeTier: .budget), 0.85)
        XCTAssertEqual(RegionalCostMultiplier.multiplier(country: nil, storeTier: nil), 1.0)
    }

    func testHelperCopy() {
        XCTAssertEqual(
            PlanBudgetHelper.helperText(people: 2, storeName: "Aldi", spend: .init(low: 65, high: 95)),
            "People cooking for 2 at Aldi usually spend about $65–$95 a week on dinners"
        )
    }

    func testBudgetFollowsDefaultUntilUserChoosesThenOnlyClamps() {
        var s = onboarding()
        s.selectPeople(2)
        s.selectStore(PlanStore.named("Kroger")!)
        XCTAssertEqual(s.budget, 75)
        s.selectStore(PlanStore.named("Aldi")!)                // untouched budget tracks the new default
        XCTAssertEqual(s.budget, 65)
        s.setBudget(90)                                        // user picks
        s.selectStore(PlanStore.named("Whole Foods")!)
        XCTAssertEqual(s.budget, 90)                           // kept (within bounds)
        s.selectPeople(1)                                      // bounds shrink → clamped, not reset
        XCTAssertEqual(s.budget, min(90, s.budgetBounds.upperBound))
    }

    func testBudgetStepsAreFiveAndClamped() {
        var s = onboarding()
        s.selectStore(PlanStore.named("Kroger")!)
        let start = s.budget
        s.stepBudget(by: 1)
        XCTAssertEqual(s.budget, start + 5)
        s.stepBudget(by: -2)
        XCTAssertEqual(s.budget, start - 5)
        for _ in 0..<100 { s.stepBudget(by: -1) }
        XCTAssertEqual(s.budget, s.budgetBounds.lowerBound)
        for _ in 0..<400 { s.stepBudget(by: 1) }
        XCTAssertEqual(s.budget, s.budgetBounds.upperBound)
    }

    // MARK: People

    func testSixOrMoreSendsSix() {
        var s = onboarding()
        s.selectPeople(6)
        XCTAssertEqual(s.draft.householdSize, 6)
        XCTAssertEqual(PlanPeopleChoice.label(for: 1), "Just me")
        XCTAssertEqual(PlanPeopleChoice.label(for: 2), "2 people")
        XCTAssertEqual(PlanPeopleChoice.label(for: 6), "6 or more")
        XCTAssertEqual(PlanPeopleChoice.option(forHouseholdSize: 9), 6)
    }

    // MARK: Flow shape

    func testOnboardingHasSixStepsAndPlanSetupHasFour() {
        var full = onboarding()
        XCTAssertEqual(full.steps, [.people, .diet, .mood, .appliances, .store, .budget])
        XCTAssertEqual(full.progress, 1.0 / 6.0, accuracy: 1e-9)
        var setup = PlanQuizSession.planSetup(from: CookingPreferences(hasCompletedOnboarding: true), deviceCountry: nil)
        XCTAssertEqual(setup.steps, [.mood, .appliances, .store, .budget])
        XCTAssertEqual(setup.progress, 0.25, accuracy: 1e-9)   // scoped to 4 steps
        XCTAssertTrue(setup.isFirst)
        XCTAssertFalse(setup.back())
        XCTAssertTrue(setup.advance())
        XCTAssertFalse(setup.advance(), "appliances is required, can't advance without one")
        XCTAssertTrue(full.advance())
        XCTAssertTrue(full.back())
    }

    func testContinueBlocksAdvanceUntilValid() {
        var s = onboarding()
        s.advance(); s.advance(); s.advance()                  // → appliances
        XCTAssertEqual(s.step, .appliances)
        XCTAssertFalse(s.advance())
        s.toggleAppliance(.stovetop)
        XCTAssertTrue(s.advance())
        XCTAssertEqual(s.step, .store)
        XCTAssertFalse(s.advance())                            // store required
    }

    func testCountryDefaultsFromDeviceRegionButKeepsStored() {
        XCTAssertEqual(onboarding().draft.country, "US")
        XCTAssertEqual(PlanQuizSession.onboarding(from: CookingPreferences(country: "GB"), deviceCountry: "US").draft.country, "GB")
    }

    // MARK: Existing-user setup trigger

    func testNeedsPlanSetupOnlyForOnboardedUsersMissingAppliancesOrStore() {
        // Updated from 1.0: onboarded, none of the new answers.
        XCTAssertTrue(CookingPreferences(hasCompletedOnboarding: true).needsPlanSetup)
        // Appliances but no store, and vice-versa.
        XCTAssertTrue(CookingPreferences(appliances: [.oven], hasCompletedOnboarding: true).needsPlanSetup)
        XCTAssertTrue(CookingPreferences(storeName: "Aldi", hasCompletedOnboarding: true).needsPlanSetup)
        // Fully answered (moods are optional, so none is fine).
        XCTAssertFalse(CookingPreferences(appliances: [.oven], storeName: "Aldi", hasCompletedOnboarding: true).needsPlanSetup)
        // Not onboarded yet: the onboarding quiz will ask, not the setup flow.
        XCTAssertFalse(CookingPreferences(hasCompletedOnboarding: false).needsPlanSetup)
    }

    func testV1PreferencesJSONDecodesAndTriggersSetup() throws {
        let json = #"{"primaryGoal":"planMyWeek","dietaryPreferences":["vegan"],"householdSize":3,"country":"US","areaType":"city","hasCompletedOnboarding":true}"#
        let prefs = try JSONDecoder().decode(CookingPreferences.self, from: Data(json.utf8))
        XCTAssertTrue(prefs.needsPlanSetup)
        XCTAssertTrue(prefs.foodMoods.isEmpty)
        XCTAssertTrue(prefs.appliances.isEmpty)
        XCTAssertNil(prefs.storeName)
        XCTAssertNil(prefs.weeklyBudget)
        XCTAssertEqual(prefs.householdSize, 3)
    }

    func testUnknownMoodOrApplianceFromANewerBuildIsDroppedNotFatal() throws {
        let json = #"{"householdSize":2,"foodMoods":["spicy","teleporting"],"appliances":["oven","jetpack"],"hasCompletedOnboarding":true}"#
        let prefs = try JSONDecoder().decode(CookingPreferences.self, from: Data(json.utf8))
        XCTAssertEqual(prefs.foodMoods, [.spicy])
        XCTAssertEqual(prefs.appliances, [.oven])
    }

    // MARK: New plan pre-fill

    func testNewPlanPrefillsEveryCurrentAnswerAndLandsOnBudgetLast() {
        let prefs = CookingPreferences(
            dietaryPreferences: [.vegetarian], householdSize: 4, country: "CA",
            foodMoods: [.comfort, .highProtein], appliances: [.stovetop, .oven], storeName: "Costco",
            weeklyBudget: 190, hasCompletedOnboarding: true
        )
        var s = PlanQuizSession.planSetup(from: prefs, deviceCountry: "US")
        XCTAssertEqual(s.step, .mood)
        XCTAssertEqual(s.draft.foodMoods, [.comfort, .highProtein])
        XCTAssertEqual(s.draft.appliances, [.stovetop, .oven])
        XCTAssertEqual(s.draft.storeName, "Costco")
        XCTAssertEqual(s.draft.country, "CA")                  // stored country wins over device region
        XCTAssertEqual(s.draft.dietaryPreferences, [.vegetarian])
        XCTAssertEqual(s.budget, 190)                          // last used budget
        // Every screen is already valid, so Continue is enabled all the way through.
        while !s.isLast { XCTAssertTrue(s.canContinue); s.advance() }
        XCTAssertEqual(s.step, .budget)
        XCTAssertTrue(s.isLast)
        XCTAssertEqual(s.draft.weeklyBudget, 190)
    }

    func testLastBudgetFallbackForAccountsThatPredateStoredBudget() {
        let prefs = CookingPreferences(householdSize: 2, appliances: [.oven], storeName: "Kroger", hasCompletedOnboarding: true)
        XCTAssertEqual(PlanQuizSession.planSetup(from: prefs, deviceCountry: nil, lastBudget: 120).budget, 120)
        XCTAssertEqual(PlanQuizSession.planSetup(from: prefs, deviceCountry: nil, lastBudget: nil).budget, 75)   // typical low
    }

    func testPrefilledBudgetIsClampedIntoCurrentBounds() {
        let prefs = CookingPreferences(householdSize: 1, appliances: [.oven], storeName: "Aldi", weeklyBudget: 400, hasCompletedOnboarding: true)
        let s = PlanQuizSession.planSetup(from: prefs, deviceCountry: nil)
        XCTAssertEqual(s.budget, s.budgetBounds.upperBound)
    }

    // MARK: Request options

    func testPlanOptionsAreSentInStableOrderAndOmittedWhenEmpty() {
        let prefs = CookingPreferences(
            foodMoods: [.quick, .comfort], appliances: [.kettle, .stovetop], storeName: "Target", hasCompletedOnboarding: true
        )
        XCTAssertEqual(prefs.planOptions, BudgetPlanOptions(
            storeTier: "standard", appliances: ["stovetop", "kettle"], foodMoods: ["comfort", "quick"]
        ))
        XCTAssertEqual(CookingPreferences().planOptions, .none)
    }

    // MARK: Sync round-trip

    private func freshDefaults() -> UserDefaults { UserDefaults(suiteName: "plan-quiz-\(UUID().uuidString)")! }

    private func answeredPrefs() -> CookingPreferences {
        CookingPreferences(
            primaryGoal: .planMyWeek, dietaryPreferences: [.pescatarian, .nutFree], householdSize: 5, country: "GB",
            areaType: .rural, foodMoods: [.spicy, .lightFresh], appliances: [.airFryer, .riceCooker, .kettle],
            storeName: "Trader Joe's", weeklyBudget: 210, hasCompletedOnboarding: true
        )
    }

    func testPreferencesSyncPayloadRoundTripsThroughApplier() {
        let defaults = freshDefaults()
        let prefs = answeredPrefs()
        let payload = SyncCodec.encode(prefs)
        XCTAssertNotNil(payload)

        // "Device B": a fresh local store (reinstall / new device) receives the pull.
        let applier = LocalSyncApplier(userId: "u1", defaults: defaults)
        applier.apply(SyncChange(collection: .cookingPreferences, itemId: CookingPreferences.syncItemId,
                                 updatedAt: 1_000, payload: payload, seq: 1))

        let restored = CookingPreferencesStore(defaults: defaults, userScope: "u1").load()
        XCTAssertEqual(restored, prefs)
        XCTAssertEqual(restored?.appliances, [.airFryer, .riceCooker, .kettle])
        XCTAssertEqual(restored?.storeName, "Trader Joe's")
        XCTAssertEqual(restored?.weeklyBudget, 210)
        XCTAssertEqual(applier.appliedRevision, 1)
    }

    func testPreferencesSyncIsAccountScopedAndLastWriterWins() {
        let defaults = freshDefaults()
        let applier = LocalSyncApplier(userId: "u1", defaults: defaults)
        var newer = answeredPrefs(); newer.weeklyBudget = 300
        var older = answeredPrefs(); older.weeklyBudget = 100
        applier.apply(SyncChange(collection: .cookingPreferences, itemId: CookingPreferences.syncItemId,
                                 updatedAt: 2_000, payload: SyncCodec.encode(newer)))
        applier.apply(SyncChange(collection: .cookingPreferences, itemId: CookingPreferences.syncItemId,
                                 updatedAt: 1_000, payload: SyncCodec.encode(older)))   // stale → ignored
        XCTAssertEqual(CookingPreferencesStore(defaults: defaults, userScope: "u1").load()?.weeklyBudget, 300)
        XCTAssertNil(CookingPreferencesStore(defaults: defaults, userScope: "u2").load())
    }

    func testRemotePreferencesNeverUndoLocalOnboardingCompletion() {
        let defaults = freshDefaults()
        let store = CookingPreferencesStore(defaults: defaults, userScope: "u1")
        store.save(CookingPreferences(hasCompletedOnboarding: true))
        var remote = answeredPrefs(); remote.hasCompletedOnboarding = false
        LocalSyncApplier(userId: "u1", defaults: defaults).apply(
            SyncChange(collection: .cookingPreferences, itemId: CookingPreferences.syncItemId, updatedAt: 5, payload: SyncCodec.encode(remote))
        )
        XCTAssertEqual(store.load()?.hasCompletedOnboarding, true)
        XCTAssertEqual(store.load()?.storeName, "Trader Joe's")
    }

    func testCollectionRawValueMatchesServerAllowlist() {
        XCTAssertEqual(SyncCollection.cookingPreferences.rawValue, "cooking_preferences")
    }

    func testPreferencesRecordSurvivesTheOutboxRoundTrip() throws {
        let change = SyncChange(collection: .cookingPreferences, itemId: CookingPreferences.syncItemId,
                                updatedAt: 42, payload: SyncCodec.encode(answeredPrefs()))
        let outbox = SyncOutbox(userId: "u1", defaults: freshDefaults())
        outbox.enqueue(change)
        XCTAssertEqual(outbox.pending(), [change])
        let wire = try JSONEncoder().encode(change)
        XCTAssertTrue(String(decoding: wire, as: UTF8.self).contains("\"cooking_preferences\""))
    }

    /// Full path: device A records its answers → server → a fresh device B (a
    /// reinstall) pulls them into its own store, including "onboarding completed".
    func testAnswersSurviveReinstallViaServer() async throws {
        let server = FakeSyncServer()
        let prefs = answeredPrefs()

        let defaultsA = freshDefaults()
        let engineA = SyncEngine(
            transport: FakeTransport(server: server),
            outbox: SyncOutbox(userId: "u1", defaults: defaultsA),
            cursorStore: SyncCursorStore(userId: "u1", defaults: defaultsA),
            apply: { _ in }
        )
        engineA.record(SyncChange(collection: .cookingPreferences, itemId: CookingPreferences.syncItemId,
                                  updatedAt: syncNowMillis(), payload: SyncCodec.encode(prefs)))
        try await engineA.sync()

        let defaultsB = freshDefaults()                        // fresh install: nothing local
        XCTAssertNil(CookingPreferencesStore(defaults: defaultsB, userScope: "u1").load())
        let applierB = LocalSyncApplier(userId: "u1", defaults: defaultsB)
        let engineB = SyncEngine(
            transport: FakeTransport(server: server),
            outbox: SyncOutbox(userId: "u1", defaults: defaultsB),
            cursorStore: SyncCursorStore(userId: "u1", defaults: defaultsB),
            apply: { applierB.apply($0) }
        )
        try await engineB.sync()

        let restored = CookingPreferencesStore(defaults: defaultsB, userScope: "u1").load()
        XCTAssertEqual(restored, prefs)
        XCTAssertEqual(restored?.hasCompletedOnboarding, true)
    }
}

final class PlanLoadingScriptTests: XCTestCase {
    func testLinesFromFullAnswers() {
        let prefs = CookingPreferences(
            dietaryPreferences: [.noRestrictions], householdSize: 2,
            foodMoods: [.comfort, .quick], appliances: [.stovetop, .microwave, .airFryer],
            storeName: "Aldi", weeklyBudget: 75
        )
        XCTAssertEqual(PlanLoadingScript.answerLines(for: prefs), [
            "2 people", "No restrictions", "Comfort food · Quick",
            "Stovetop, microwave, air fryer", "Aldi prices",
        ])
        XCTAssertEqual(PlanLoadingScript.finalLine(budget: 75), "Fitting it into $75")
    }

    func testNoMoodsSingleApplianceOtherStoreAndSinglePerson() {
        let prefs = CookingPreferences(
            dietaryPreferences: [.vegetarian, .glutenFree], householdSize: 1,
            appliances: [.oven], storeName: PlanStore.otherName
        )
        XCTAssertEqual(PlanLoadingScript.answerLines(for: prefs), ["1 person", "Vegetarian, Gluten-free", "Oven"])
    }

    func testSkippedQuizStillHasPeopleAndDiet() {
        XCTAssertEqual(PlanLoadingScript.answerLines(for: CookingPreferences()), ["2 people", "No restrictions"])
    }

    func testRemainingHold() {
        let t0 = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(PlanLoadingTiming.remainingHold(started: t0, now: t0.addingTimeInterval(1.5)), 2.5, accuracy: 0.001)
        XCTAssertEqual(PlanLoadingTiming.remainingHold(started: t0, now: t0.addingTimeInterval(4)), 0)
        XCTAssertEqual(PlanLoadingTiming.remainingHold(started: t0, now: t0.addingTimeInterval(20)), 0)
        XCTAssertEqual(PlanLoadingTiming.minimumDuration, 4)
    }

    func testTeaserPolicy() {
        let none: (String) -> Bool = { _ in false }
        XCTAssertTrue(PaywallTeaserPolicy.shouldShow(.freePlanReveal(planKey: "a"), isPro: false, alreadyShown: none))
        XCTAssertFalse(PaywallTeaserPolicy.shouldShow(.freePlanReveal(planKey: "a"), isPro: false, alreadyShown: { $0 == "a" }))
        XCTAssertFalse(PaywallTeaserPolicy.shouldShow(.freePlanReveal(planKey: "a"), isFreePlan: false, isPro: false, alreadyShown: none))
        for trigger in [PaywallTeaserTrigger.freePlanReveal(planKey: "a"), .newPlanOnFreePlan] {
            XCTAssertFalse(PaywallTeaserPolicy.shouldShow(trigger, isPro: true, alreadyShown: none))
        }
        XCTAssertTrue(PaywallTeaserPolicy.shouldShow(.freePlanUsed, isPro: false, alreadyShown: none))
        XCTAssertTrue(PaywallTeaserPolicy.shouldShow(.freeSwapsUsed, isPro: false, alreadyShown: none))
        XCTAssertTrue(PaywallTeaserPolicy.shouldShow(.newPlanOnFreePlan, isPro: false, alreadyShown: none))
    }

    func testTeaserStorePersistsPerAccount() {
        let d = UserDefaults(suiteName: "teaser-\(UUID().uuidString)")!
        let a = PaywallTeaserStore(defaults: d, userScope: "a")
        a.markShown(planKey: "p1")
        XCTAssertTrue(PaywallTeaserStore(defaults: d, userScope: "a").hasShown(planKey: "p1"))
        XCTAssertFalse(PaywallTeaserStore(defaults: d, userScope: "b").hasShown(planKey: "p1"))
        XCTAssertFalse(a.hasShown(planKey: "p2"))
    }
}
