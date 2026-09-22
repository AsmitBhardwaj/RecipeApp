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

public enum DietaryPreference: String, Codable, CaseIterable, Hashable, Sendable {
    case vegetarian
    case vegan
    case glutenFree
    case dairyFree
    case noRestrictions

    public var displayName: String {
        switch self {
        case .vegetarian: "Vegetarian"
        case .vegan: "Vegan"
        case .glutenFree: "Gluten-free"
        case .dairyFree: "Dairy-free"
        case .noRestrictions: "No restrictions"
        }
    }
}

public struct CookingPreferences: Codable, Equatable, Sendable {
    public var primaryGoal: PrimaryCookingGoal?
    public var dietaryPreferences: Set<DietaryPreference>
    public var householdSize: Int
    /// The user's grocery-cost region (drives the Plan on a Budget multiplier).
    /// Optional and decoded leniently so preferences saved before this field
    /// existed still load.
    public var region: GroceryRegion?
    public var hasCompletedOnboarding: Bool

    public init(
        primaryGoal: PrimaryCookingGoal? = nil,
        dietaryPreferences: Set<DietaryPreference> = [],
        householdSize: Int = 2,
        region: GroceryRegion? = nil,
        hasCompletedOnboarding: Bool = false
    ) {
        self.primaryGoal = primaryGoal
        self.dietaryPreferences = Self.normalized(dietaryPreferences)
        self.householdSize = min(max(householdSize, 1), 12)
        self.region = region
        self.hasCompletedOnboarding = hasCompletedOnboarding
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        primaryGoal = try c.decodeIfPresent(PrimaryCookingGoal.self, forKey: .primaryGoal)
        let diet = try c.decodeIfPresent(Set<DietaryPreference>.self, forKey: .dietaryPreferences) ?? []
        dietaryPreferences = Self.normalized(diet)
        householdSize = min(max(try c.decodeIfPresent(Int.self, forKey: .householdSize) ?? 2, 1), 12)
        region = try c.decodeIfPresent(GroceryRegion.self, forKey: .region)
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

    private static func normalized(_ values: Set<DietaryPreference>) -> Set<DietaryPreference> {
        values.contains(.noRestrictions) ? [.noRestrictions] : values
    }
}
