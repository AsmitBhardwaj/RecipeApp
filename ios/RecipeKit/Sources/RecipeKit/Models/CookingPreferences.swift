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
    /// The user's grocery-cost country as an ISO 3166-1 alpha-2 code (e.g. "US").
    /// Optional and decoded leniently so older preferences still load.
    public var country: String?
    /// The user's area type (City/Suburb/Rural). Combined with `country` to drive
    /// the Plan on a Budget cost multiplier.
    public var areaType: AreaType?
    public var hasCompletedOnboarding: Bool

    public init(
        primaryGoal: PrimaryCookingGoal? = nil,
        dietaryPreferences: Set<DietaryPreference> = [],
        householdSize: Int = 2,
        country: String? = nil,
        areaType: AreaType? = nil,
        hasCompletedOnboarding: Bool = false
    ) {
        self.primaryGoal = primaryGoal
        self.dietaryPreferences = Self.normalized(dietaryPreferences)
        self.householdSize = min(max(householdSize, 1), 12)
        self.country = country
        self.areaType = areaType
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

    private static func normalized(_ values: Set<DietaryPreference>) -> Set<DietaryPreference> {
        values.contains(.noRestrictions) ? [.noRestrictions] : values
    }
}
