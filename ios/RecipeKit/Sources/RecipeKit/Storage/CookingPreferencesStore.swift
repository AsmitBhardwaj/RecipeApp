import Foundation

public struct CookingPreferencesStore {
    private static let baseKey = "cooking_preferences_v1"
    private let defaults: UserDefaults
    private let storageKey: String

    public init(suiteName: String = AppGroup.identifier, userScope: String) {
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
        storageKey = scopedStorageKey(Self.baseKey, userScope)
    }

    public init(defaults: UserDefaults, userScope: String) {
        self.defaults = defaults
        storageKey = scopedStorageKey(Self.baseKey, userScope)
    }

    public func load() -> CookingPreferences? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(CookingPreferences.self, from: data)
    }

    public func save(_ preferences: CookingPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
