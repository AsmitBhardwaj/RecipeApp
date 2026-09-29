import Foundation

public enum PrimaryCookingGoal: String, Codable, CaseIterable, Hashable, Sendable {
    case cookFaster
    case useWhatIHave
    case planMyWeek
    case eatMoreVariety

    public var displayName: String {
        switch self {
        case .cookFaster: "Cook faster"
        case .useWhatIHave: "Use what I have"
        case .planMyWeek: "Plan my week"
        case .eatMoreVariety: "Eat more variety"
        }
    }
}

/// Declaration order is the display order of the onboarding diet screen.
public enum DietaryPreference: String, Codable, CaseIterable, Hashable, Sendable {
    case noRestrictions
    case vegetarian
    case vegan
    case pescatarian
    case glutenFree
    case dairyFree
    case halal
    case kosher
    case nutFree

    public var displayName: String {
        switch self {
        case .noRestrictions: "No restrictions"
        case .vegetarian: "Vegetarian"
        case .vegan: "Vegan"
        case .pescatarian: "Pescatarian"
        case .glutenFree: "Gluten-free"
        case .dairyFree: "Dairy-free"
        case .halal: "Halal"
        case .kosher: "Kosher"
        case .nutFree: "Nut-free"
        }
    }
}

public struct CookingPreferences: Codable, Equatable, Sendable {
    /// The single sync item id: the whole record is one item in `cooking_preferences`.
    public static let syncItemId = "preferences"

    public var primaryGoal: PrimaryCookingGoal?
    public var dietaryPreferences: Set<DietaryPreference>
    public var householdSize: Int
    /// The user's grocery-cost country as an ISO 3166-1 alpha-2 code (e.g. "US").
    /// Optional and decoded leniently so older preferences still load.
    public var country: String?
    /// The user's area type (City/Suburb/Rural). Combined with `country` to drive
    /// the Plan on a Budget cost multiplier.
    public var areaType: AreaType?
    /// Plan-quiz answers. `foodMoods` is a soft steer (0–3 allowed); `appliances`
    /// is a hard constraint on generation. `storeName` is the label the user
    /// picked (its tier is derived — see `PlanStore`). `weeklyBudget` is the last
    /// budget the user confirmed (dinners only).
    public var foodMoods: Set<FoodMood>
    public var appliances: Set<Appliance>
    public var storeName: String?
    public var weeklyBudget: Int?
    public var hasCompletedOnboarding: Bool

    public init(
        primaryGoal: PrimaryCookingGoal? = nil,
        dietaryPreferences: Set<DietaryPreference> = [],
        householdSize: Int = 2,
        country: String? = nil,
        areaType: AreaType? = nil,
        foodMoods: Set<FoodMood> = [],
        appliances: Set<Appliance> = [],
        storeName: String? = nil,
        weeklyBudget: Int? = nil,
        hasCompletedOnboarding: Bool = false
    ) {
        self.primaryGoal = primaryGoal
        self.dietaryPreferences = Self.normalized(dietaryPreferences)
        self.householdSize = min(max(householdSize, 1), 12)
        self.country = country
        self.areaType = areaType
        self.foodMoods = Set(foodMoods.sorted { $0.sortIndex < $1.sortIndex }.prefix(FoodMood.maxSelection))
        self.appliances = appliances
        self.storeName = storeName
        self.weeklyBudget = weeklyBudget
        self.hasCompletedOnboarding = hasCompletedOnboarding
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        primaryGoal = try c.decodeIfPresent(PrimaryCookingGoal.self, forKey: .primaryGoal)
        let diet = try c.decodeIfPresent(Set<DietaryPreference>.self, forKey: .dietaryPreferences) ?? []
        dietaryPreferences = Self.normalized(diet)
        householdSize = min(max(try c.decodeIfPresent(Int.self, forKey: .householdSize) ?? 2, 1), 12)
        country = try c.decodeIfPresent(String.self, forKey: .country)
        areaType = try c.decodeIfPresent(AreaType.self, forKey: .areaType)
        // Quiz answers decode leniently: a value this build doesn't know (added by
        // a newer app version on another device) is dropped, never a failed load.
        let moods = try c.decodeIfPresent([String].self, forKey: .foodMoods) ?? []
        foodMoods = Set(moods.compactMap(FoodMood.init(rawValue:)).sorted { $0.sortIndex < $1.sortIndex }.prefix(FoodMood.maxSelection))
        let tools = try c.decodeIfPresent([String].self, forKey: .appliances) ?? []
        appliances = Set(tools.compactMap(Appliance.init(rawValue:)))
        storeName = try c.decodeIfPresent(String.self, forKey: .storeName)
        weeklyBudget = try c.decodeIfPresent(Int.self, forKey: .weeklyBudget)
        // The old single `region` field (removed) is intentionally not decoded:
        // existing users silently default to unset and re-pick country + area type.
        hasCompletedOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
    }

    public mutating func setDietaryPreference(_ preference: DietaryPreference, selected: Bool) {
        if preference == .noRestrictions {
            dietaryPreferences = selected ? [.noRestrictions] : []
        } else {
            dietaryPreferences.remove(.noRestrictions)
            if selected { dietaryPreferences.insert(preference) }
            else { dietaryPreferences.remove(preference) }
        }
    }

    // MARK: - Plan quiz answers

    /// Toggle a food mood. Selecting a 4th is refused (returns false); deselecting
    /// always works.
    @discardableResult
    public mutating func toggleFoodMood(_ mood: FoodMood) -> Bool {
        if foodMoods.contains(mood) {
            foodMoods.remove(mood)
            return true
        }
        guard foodMoods.count < FoodMood.maxSelection else { return false }
        foodMoods.insert(mood)
        return true
    }

    public mutating func toggleAppliance(_ appliance: Appliance) {
        if appliances.contains(appliance) { appliances.remove(appliance) }
        else { appliances.insert(appliance) }
    }

    public mutating func setStore(_ store: PlanStore) {
        storeName = store.name
    }

    /// The selected store, if it is one of the known tiles.
    public var store: PlanStore? { storeName.flatMap(PlanStore.named) }

    /// The price tier sent to the server as `store_tier`. Nil until a store is picked.
    public var storeTier: StoreTier? { storeName.map(PlanStore.tier(forStoreName:)) }

    /// Moods in a stable (declaration) order, for sending.
    public var orderedFoodMoods: [FoodMood] { FoodMood.allCases.filter(foodMoods.contains) }

    /// Appliances in a stable (declaration) order, for sending.
    public var orderedAppliances: [Appliance] { Appliance.allCases.filter(appliances.contains) }

    /// The v1.1 request fields this user's answers produce. Empty moods / no
    /// appliances / no store are omitted, keeping the request v1.0-shaped.
    public var planOptions: BudgetPlanOptions {
        BudgetPlanOptions(
            storeTier: storeTier?.rawValue,
            appliances: appliances.isEmpty ? nil : orderedAppliances.map(\.rawValue),
            foodMoods: foodMoods.isEmpty ? nil : orderedFoodMoods.map(\.rawValue)
        )
    }

    /// An onboarded user who never saw the plan quiz (updated from 1.0): appliances
    /// or store is missing. Moods are optional, so they never count as missing.
    /// Plan on a Budget runs the setup flow for them before generating.
    public var needsPlanSetup: Bool {
        hasCompletedOnboarding && (appliances.isEmpty || storeName == nil)
    }

    private static func normalized(_ values: Set<DietaryPreference>) -> Set<DietaryPreference> {
        values.contains(.noRestrictions) ? [.noRestrictions] : values
    }
}
